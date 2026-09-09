# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[sets, sequtils, strutils]
import chronos, chronicles
import ../[multiaddress, multicodec]

logScope:
  topics = "libp2p nameresolver"

const
  MaxDnsLookups* = 32
  ## Bounds the amount of DNS work caused by one multiaddress.

  MaxDnsaddrRecursion* = 4
  ## Matches go-libp2p's DNSADDR recursion limit.

  MaxDnsaddrRecords* = 16
  ## Matches rust-libp2p's per-query TXT record limit.

  MaxResolvedAddresses* = 100
  ## Matches go-libp2p's maximum number of resolved addresses.

  MaxResolutionQueue = MaxDnsLookups * MaxResolvedAddresses
  ## Intermediate addresses are bounded separately from final output.

type
  NameResolver* = ref object of RootObj

  DnsComponent = object
    found: bool
    index: int
    code: MultiCodec
    name: string

  DnsaddrResolutionState = ref object
    lookups: int
    emitted: int
    seen: HashSet[MultiAddress]
    outputs: HashSet[MultiAddress]

method resolveTxt*(
    self: NameResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]), base.} =
  ## Get TXT record
  raiseAssert "[NameResolver.resolveTxt] abstract method not implemented!"

method resolveIp*(
    self: NameResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError]), base
.} =
  ## Resolve the specified address
  raiseAssert "[NameResolver.resolveIp] abstract method not implemented!"

method close*(self: NameResolver) {.base, async: (raises: []).} =
  ## Release resources owned by the resolver.
  ##
  ## Most resolvers do not own any resources. Resolvers which do (for example,
  ## worker-backed system resolvers) override this method.
  discard

proc isDnsCode(code: MultiCodec): bool =
  code == multiCodec("dns") or code == multiCodec("dns4") or
    code == multiCodec("dns6") or code == multiCodec("dnsaddr")

proc argumentString(part: MultiAddress): string {.raises: [MaError].} =
  let argument = part.protoArgument().valueOr:
    raise maErr error
  result = newString(argument.len)
  for i, value in argument:
    result[i] = char(value)

proc findDnsComponent(
    ma: MultiAddress, dnsaddrOnly = false
): DnsComponent {.raises: [MaError].} =
  var index = 0
  for partResult in ma:
    let part = partResult.valueOr:
      raise maErr error
    let code = part.protoCode().valueOr:
      raise maErr error
    if (if dnsaddrOnly: code == multiCodec("dnsaddr") else: isDnsCode(code)):
      return DnsComponent(
        found: true, index: index, code: code, name: argumentString(part)
      )
    inc index

proc containsDnsComponent*(ma: MultiAddress): bool =
  ## Returns true when any component, not only the first one, needs DNS.
  for partResult in ma:
    let part = partResult.valueOr:
      return false
    let code = part.protoCode().valueOr:
      return false
    if isDnsCode(code):
      return true
  false

proc components(ma: MultiAddress): seq[MultiAddress] {.raises: [MaError].} =
  for partResult in ma:
    let part = partResult.valueOr:
      raise maErr error
    result.add(part)

proc sameComponent(left, right: MultiAddress): bool =
  var comparable = left
  comparable == right

proc endsWith(
    candidate: MultiAddress, suffix: openArray[MultiAddress]
): bool {.raises: [MaError].} =
  if suffix.len == 0:
    return true

  let candidateParts = components(candidate)
  if candidateParts.len < suffix.len:
    return false

  let offset = candidateParts.len - suffix.len
  for i in 0 ..< suffix.len:
    if not sameComponent(candidateParts[offset + i], suffix[i]):
      return false
  true

proc prepend(
    prefix: openArray[MultiAddress], address: MultiAddress
): MultiAddress {.raises: [MaError].} =
  result = MultiAddress.init()
  for part in prefix:
    result &= part
  result &= address

proc replaceComponent(
    ma: MultiAddress, index: int, replacement: MultiAddress
): MultiAddress {.raises: [MaError].} =
  result = MultiAddress.init()
  var current = 0
  for partResult in ma:
    let part = partResult.valueOr:
      raise maErr error
    result &= (if current == index: replacement else: part)
    inc current

proc getHostname*(ma: MultiAddress): string =
  ## Returns the first DNS name, or the first IP literal when no DNS component
  ## is present. Preferring DNS preserves the Host/SNI value when a resolvable
  ## address appears behind a relay prefix.
  var firstIp = ""
  for partResult in ma:
    let part = partResult.valueOr:
      return ""
    let code = part.protoCode().valueOr:
      return ""
    if isDnsCode(code):
      try:
        return argumentString(part)
      except MaError:
        return ""
    if firstIp.len == 0 and
        (code == multiCodec("ip4") or code == multiCodec("ip6")):
      let rendered = ($part).split('/', 2)
      if rendered.len > 2:
        firstIp = rendered[2]
  firstIp

proc resolveOneAddress(
    self: NameResolver,
    ma: MultiAddress,
    component: DnsComponent,
    domain: Domain = Domain.AF_UNSPEC,
): Future[seq[MultiAddress]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError])
.} =
  ## Replace one DNS component and preserve every component around it.
  ##
  ## The resolver API carries a port because it returns TransportAddress, but
  ## multiaddr replacement only needs the IP component. Port zero also permits
  ## resolving addresses which do not yet contain a transport component.
  let resolvedAddresses = await self.resolveIp(component.name, Port(0), domain)

  for resolvedAddr in resolvedAddresses:
    let address = MultiAddress.init(resolvedAddr).valueOr:
      raise maErr error
    let ipComponent = address[0].valueOr:
      raise maErr error
    result.add(replaceComponent(ma, component.index, ipComponent))

proc resolveDnsAddrImpl(
    self: NameResolver,
    ma: MultiAddress,
    depth: int,
    state: DnsaddrResolutionState,
): Future[seq[MultiAddress]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError])
.} =
  let component = findDnsComponent(ma, dnsaddrOnly = true)
  if not component.found:
    if state.emitted >= MaxResolvedAddresses or state.outputs.containsOrIncl(ma):
      return @[]
    inc state.emitted
    return @[ma]

  if depth >= MaxDnsaddrRecursion or state.lookups >= MaxDnsLookups:
    info "Stopping DNSADDR recursion at the resolution limit", ma
    return @[]

  if state.seen.containsOrIncl(ma):
    info "Stopping cyclic DNSADDR resolution", ma
    return @[]

  inc state.lookups
  trace "Resolving dnsaddr", ma
  let txt = await self.resolveTxt("_dnsaddr." & component.name)
  trace "txt entries", txt

  let maParts = components(ma)
  var
    prefix: seq[MultiAddress]
    suffix: seq[MultiAddress]
  for i in 0 ..< component.index:
    prefix.add(maParts[i])
  for i in (component.index + 1) ..< maParts.len:
    suffix.add(maParts[i])

  for i in 0 ..< min(txt.len, MaxDnsaddrRecords):
    if state.emitted >= MaxResolvedAddresses:
      break

    let entry = txt[i]
    if not entry.startsWith("dnsaddr=") or entry.len <= "dnsaddr=".len:
      continue

    let parsed = MultiAddress.init(entry.substr("dnsaddr=".len))
    if parsed.isErr:
      debug "Skipping invalid DNSADDR TXT entry", entry, description = parsed.error
      continue

    let entryValue = parsed.get()
    if not entryValue.endsWith(suffix):
      continue

    let expanded = prepend(prefix, entryValue)
    for resolved in await self.resolveDnsAddrImpl(expanded, depth + 1, state):
      result.add(resolved)

  if result.len == 0:
    debug "Failed to resolve a DNSADDR", ma

proc resolveDnsAddr*(
    self: NameResolver, ma: MultiAddress, depth: int = 0
): Future[seq[MultiAddress]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError])
.} =
  let state = DnsaddrResolutionState(
    seen: initHashSet[MultiAddress](), outputs: initHashSet[MultiAddress]()
  )
  await self.resolveDnsAddrImpl(ma, depth, state)

proc resolveMAddress*(
    self: NameResolver, address: MultiAddress
): Future[seq[MultiAddress]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError])
.} =
  var
    resolved = initOrderedSet[MultiAddress]()
    queued = initHashSet[MultiAddress]()
    pending = @[address]
    next = 0
    lookups = 0
  queued.incl(address)

  while next < pending.len and resolved.len < MaxResolvedAddresses:
    let current = pending[next]
    inc next

    let component = findDnsComponent(current)
    if not component.found:
      resolved.incl(current)
      continue

    if lookups >= MaxDnsLookups:
      info "Stopping DNS resolution at the lookup limit", address
      break
    inc lookups

    let addresses =
      case component.code
      of multiCodec("dns"):
        await self.resolveOneAddress(current, component)
      of multiCodec("dns4"):
        await self.resolveOneAddress(current, component, Domain.AF_INET)
      of multiCodec("dns6"):
        await self.resolveOneAddress(current, component, Domain.AF_INET6)
      of multiCodec("dnsaddr"):
        await self.resolveDnsAddr(current)
      else:
        raise maErr("Unsupported codec " & $component.code)

    for resolvedAddress in addresses:
      if pending.len >= MaxResolutionQueue:
        debug "Dropping DNS results over the resolution queue limit",
          limit = MaxResolutionQueue
        break
      if not queued.containsOrIncl(resolvedAddress):
        pending.add(resolvedAddress)

  resolved.toSeq
