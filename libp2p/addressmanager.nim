# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## The `AddressManager` owns the addresses a node announces. It keeps one
## candidate per address, it maps each local listen address to the external
## address that remote peers report for it, and it runs the only
## `AddressMapper` the local `PeerInfo` holds. The wildcard resolver, the NAT
## port mapper, AutoNAT, AutoRelay and the explicit announce list all feed it.

{.push raises: [].}

import std/[sequtils, sets, tables]
import chronos
import multiaddress, multicodec, peerinfo, wildcardaddrs

export NetworkInterfaceProvider, getAddresses, expandWildcardAddresses

const
  DefaultObservedAddrMaxSize* = 10
  DefaultObservedAddrMinCount* = 3
  DefaultCandidateTtl* = 30.minutes

type
  AddrSource* {.pure.} = enum
    IdentifyObserved
    Upnp
    NatPmp
    Circuit
    Listen
    Announced

  AddrState* {.pure.} = enum
    Unverified
    Confirmed
    Unreachable

  AddrCandidate* = object
    address*: MultiAddress
    source*: AddrSource
    state*: AddrState
    lastChecked*: Moment
    ttl*: Duration

  AddressManagerConfig* = object
    maxSize*: int = DefaultObservedAddrMaxSize
    minCount*: int = DefaultObservedAddrMinCount
    candidateTtl*: Duration = DefaultCandidateTtl

  SourcedMapper = object
    mapper: AddressMapper
    source: AddrSource

  AddressManager* = ref object of RootObj
    observations: OrderedTable[MultiAddress, seq[MultiAddress]]
    candidates: OrderedTable[MultiAddress, AddrCandidate]
    mappers: seq[SourcedMapper]
    chainAddrs: HashSet[MultiAddress]
    peerInfo: PeerInfo
    addressMapper: AddressMapper
    localAddrs: seq[MultiAddress]
    ## the wildcard-expanded listen addresses of the last chain run; an
    ## observation keys on one of them
    networkInterfaceProvider: NetworkInterfaceProvider
    maxSize: int
    minCount: int
    candidateTtl: Duration
    started: bool

func isStarted*(self: AddressManager): bool =
  self.started

proc observationKey(self: AddressManager, localAddr: Opt[MultiAddress]): MultiAddress =
  ## An outbound connection reports the ephemeral local port, which maps to no
  ## listen address. Those observations share one window, so that the table
  ## cannot grow with one entry per port.
  let local = localAddr.valueOr:
    return MultiAddress()
  if local notin self.localAddrs:
    return MultiAddress()
  local

proc isDialableIp(ip: IpAddress): bool =
  case ip.family
  of IpAddressFamily.IPv4:
    # the unspecified address, the multicast range, and the reserved range
    ip.address_v4 != AnyAddress.address_v4 and ip.address_v4[0] < 224'u8
  of IpAddressFamily.IPv6:
    ip.address_v6 != AnyAddress6.address_v6 and ip.address_v6[0] != 0xff'u8

proc addObservation*(
    self: AddressManager, observedAddr: MultiAddress, localAddr = Opt.none(MultiAddress)
): bool =
  ## Records the address a remote peer reports for `localAddr`. Returns false
  ## when the manager is not started, or when the address is not a dialable IP
  ## address with a transport.
  if not self.started:
    return false

  # a remote peer picks what it reports: junk would only evict a useful entry
  if not (observedAddr.hasIp() and observedAddr.hasTransport()) or
      observedAddr.contains(multiCodec("p2p-circuit")).get(false):
    return false

  let ip = observedAddr.getIp().valueOr:
    return false
  if not ip.isDialableIp():
    return false

  let key = self.observationKey(localAddr)
  var window = self.observations.getOrDefault(key)
  if window.len >= self.maxSize:
    window.delete(0)
  window.add(observedAddr)
  self.observations[key] = window
  true

proc allObservations(self: AddressManager): seq[MultiAddress] =
  var res: seq[MultiAddress]
  for window in self.observations.values:
    res.add(window)
  res

proc mostObserved(
    self: AddressManager, observations: seq[MultiAddress], code: MultiCodec
): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  for ma, count in countTable.pairs:
    let protoCode = (ma[0].flatMap(protoCode)).valueOr:
      continue
    if protoCode == code and count >= self.minCount:
      return Opt.some(ma)
  Opt.none(MultiAddress)

proc mostObservedIp(
    self: AddressManager, observations: seq[MultiAddress], code: MultiCodec
): Opt[MultiAddress] =
  var ips: seq[MultiAddress]
  for observation in observations:
    let ip = observation[0].valueOr:
      continue
    ips.add(ip)
  self.mostObserved(ips, code)

proc getMostObservedProtosAndPorts*(self: AddressManager): seq[MultiAddress] =
  ## The most observed IP4/Port and IP6/Port addresses, or an empty seq while
  ## no address reaches `minCount`.
  let observations = self.allObservations()
  var res: seq[MultiAddress]
  self.mostObserved(observations, multiCodec("ip4")).withValue(ip4):
    res.add(ip4)
  self.mostObserved(observations, multiCodec("ip6")).withValue(ip6):
    res.add(ip6)
  res

proc externalAddrFor*(self: AddressManager, listenAddr: MultiAddress): MultiAddress =
  ## Maps a local listen address to the external address peers report for it.
  ## The IP part is replaced by the most observed IP of the same protocol, the
  ## rest of the address is kept. The peers which observed this very listen
  ## address decide first, and the other observations are the fallback.
  let
    first = listenAddr[0].valueOr:
      return listenAddr
    rest = listenAddr[1 ..^ 1].valueOr:
      return listenAddr
    code = first.protoCode().valueOr:
      return listenAddr

  let observed = block:
    let onThisAddr = self.observations.getOrDefault(listenAddr)
    self.mostObservedIp(onThisAddr, code).valueOr:
      self.mostObservedIp(self.allObservations(), code).valueOr:
        return listenAddr

  concat(observed, rest).valueOr:
    listenAddr

func isExpired(candidate: AddrCandidate, now: Moment): bool =
  candidate.ttl > ZeroDuration and candidate.lastChecked + candidate.ttl < now

proc prune(self: AddressManager) =
  let now = Moment.now()
  var expired: seq[MultiAddress]
  for address, candidate in self.candidates:
    # the chain re-produces its own addresses, so it proves they are alive
    if address notin self.chainAddrs and candidate.isExpired(now):
      expired.add(address)
  for address in expired:
    self.candidates.del(address)

proc add*(
    self: AddressManager,
    address: MultiAddress,
    source: AddrSource,
    state = AddrState.Unverified,
    ttl = ZeroDuration,
): bool {.discardable.} =
  ## Adds a candidate, or refreshes the one already under `address`. A refresh
  ## keeps the state a verifier assigned. Returns true for a new candidate.
  let
    isNew = address notin self.candidates
    previous = self.candidates.getOrDefault(address)
  var candidate = AddrCandidate(
    address: address,
    source: source,
    state: if isNew: state else: previous.state,
    lastChecked:
      if isNew:
        Moment.now()
      else:
        previous.lastChecked,
    ttl: if ttl == ZeroDuration: self.candidateTtl else: ttl,
  )
  # a verified candidate keeps the time it was verified
  if candidate.state == AddrState.Unverified:
    candidate.lastChecked = Moment.now()

  self.candidates[address] = candidate
  isNew

proc update*(
    self: AddressManager, address: MultiAddress, state: AddrState
): bool {.discardable.} =
  if address notin self.candidates:
    return false
  var candidate = self.candidates.getOrDefault(address)
  candidate.state = state
  candidate.lastChecked = Moment.now()
  self.candidates[address] = candidate
  true

proc remove*(self: AddressManager, address: MultiAddress): bool {.discardable.} =
  if address notin self.candidates:
    return false
  self.candidates.del(address)
  true

proc candidates*(self: AddressManager): seq[AddrCandidate] =
  self.prune()
  toSeq(self.candidates.values)

proc confirmedAddrs*(
    self: AddressManager, family = Opt.none(IpAddressFamily)
): seq[MultiAddress] =
  ## The candidates a verifier confirmed, restricted to one IP family when
  ## `family` is given. No verifier exists yet, so this is empty until one sets
  ## a state through `update`.
  self.prune()
  var res: seq[MultiAddress]
  for candidate in self.candidates.values:
    if candidate.state != AddrState.Confirmed:
      continue
    family.withValue(wanted):
      let ip = candidate.address.getIp().valueOr:
        continue
      if ip.family != wanted:
        continue
    res.add(candidate.address)
  res

func isAnnounceable(self: AddressManager, address: MultiAddress): bool =
  # every candidate is announced until a verifier proves one unreachable
  self.candidates.getOrDefault(address).state != AddrState.Unreachable

proc addMapper*(self: AddressManager, mapper: AddressMapper, source: AddrSource) =
  ## Each address this mapper adds becomes a candidate of `source`.
  if mapper.isNil():
    return
  self.mappers.add(SourcedMapper(mapper: mapper, source: source))

proc removeMapper*(self: AddressManager, mapper: AddressMapper) =
  self.mappers.keepItIf(it.mapper != mapper)

func mapperSources*(self: AddressManager): seq[AddrSource] =
  ## In the order the chain runs them.
  self.mappers.mapIt(it.source)

proc `networkInterfaceProvider=`*(
    self: AddressManager, provider: NetworkInterfaceProvider
) =
  ## Sets the provider the wildcard resolver runs on. A nil provider announces
  ## the wildcard listen addresses as they are.
  self.networkInterfaceProvider = provider

proc expandWildcards(
    self: AddressManager, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  if self.networkInterfaceProvider.isNil():
    return listenAddrs
  expandWildcardAddresses(self.networkInterfaceProvider, listenAddrs)

proc track(self: AddressManager, addrs: seq[MultiAddress], source: AddrSource) =
  for address in addrs:
    self.add(address, source)
    self.chainAddrs.incl(address)

proc dropStaleObservations(self: AddressManager) =
  var stale: seq[MultiAddress]
  for key in self.observations.keys:
    if key != MultiAddress() and key notin self.localAddrs:
      stale.add(key)
  for key in stale:
    self.observations.del(key)

proc withdraw(self: AddressManager, kept: seq[MultiAddress]) =
  ## Drops every candidate the chain no longer produces: a NAT mapping which
  ## expires, or a relay reservation which is lost, withdraws its address here.
  ## A candidate a feeder added through `add` belongs to no mapper, so it stays.
  for address in self.chainAddrs:
    if address notin kept:
      self.candidates.del(address)
  self.chainAddrs = kept.toHashSet()

proc announceSet(
    self: AddressManager, mappedAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  var res = mappedAddrs
  for address in self.candidates.keys:
    if address notin self.chainAddrs and address notin res:
      res.add(address)
  res.filterIt(self.isAnnounceable(it))

proc explicitAddrs(self: AddressManager): seq[MultiAddress] =
  if self.peerInfo.isNil():
    return @[]
  self.peerInfo.announcedAddrs

proc resolve(
    self: AddressManager, inputAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  let announced = self.explicitAddrs()
  var addrs = self.expandWildcards(inputAddrs)
  self.localAddrs = addrs
  self.dropStaleObservations()

  self.track(addrs, AddrSource.Listen)

  for sourced in self.mappers:
    let mapped = await sourced.mapper(addrs)
    self.track(mapped.filterIt(it notin addrs), sourced.source)
    addrs = mapped

  self.track(announced, AddrSource.Announced)
  self.withdraw(addrs & announced)
  self.prune()
  self.announceSet(addrs)

proc start*(self: AddressManager, peerInfo: PeerInfo = nil) =
  ## Starts the manager and, with a `PeerInfo`, installs its mapper as the first
  ## one that `PeerInfo` runs.
  if self.started:
    return
  self.started = true

  if peerInfo.isNil():
    return
  self.peerInfo = peerInfo
  peerInfo.addressMappers.insert(self.addressMapper, 0)

proc stop*(self: AddressManager) =
  self.started = false
  self.observations.clear()
  self.candidates.clear()
  self.chainAddrs.clear()
  self.mappers.setLen(0)
  self.localAddrs.setLen(0)

  if self.peerInfo.isNil():
    return
  self.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  self.peerInfo = nil

proc `$`*(self: AddressManager): string =
  "observations: " & $self.allObservations() & ", candidates: " &
    $toSeq(self.candidates.keys)

proc new*(
    T: typedesc[AddressManager], config: AddressManagerConfig = AddressManagerConfig()
): T =
  ## A threshold below one is raised to one: an empty window has nothing to
  ## evict, and a minCount of zero would let a single peer decide the external
  ## address.
  let manager = T(
    maxSize: max(config.maxSize, 1),
    minCount: max(config.minCount, 1),
    candidateTtl: config.candidateTtl,
  )
  manager.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    await manager.resolve(listenAddrs)
  manager
