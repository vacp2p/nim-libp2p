# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## The `AddressManager` owns the addresses a node announces: one candidate per
## address, and the only `AddressMapper` the local `PeerInfo` runs. The wildcard
## resolver, the NAT port mapper, AutoNAT, AutoRelay and the explicit announce
## list all feed it.

{.push raises: [].}

import std/[sequtils, tables]
import chronos, chronos/transports/[osnet, ipnet]
import multiaddress, multicodec, peerinfo, utils/heartbeat
import protocols/connectivity/autonat/types

export NetworkReachability

logScope:
  topics = "libp2p addressmanager"

const
  DefaultObservedAddrMaxSize* = 10
  DefaultObservedAddrMinCount* = 3
  DefaultVerifyInterval* = 5.minutes

type
  NetworkInterfaceProvider* =
    proc(addrFamily: AddressFamily): seq[InterfaceAddress] {.gcsafe, raises: [].}

  AddrSource* {.pure.} = enum
    Autonat
    Identify ## guessed from the addresses which identify peers observed
    Upnp
    NatPmp
    PortMapped ## a port mapper answered and did not report which protocol it used
    ExplicitIp
    Circuit
    Listen
    Announced

  AddrState* {.pure.} = enum
    Unverified
    Confirmed
    Unreachable

  AddrCandidate* = object
    address*: MultiAddress
    sources*: set[AddrSource]
    state*: AddrState

  AddrVerdict* = object
    address*: MultiAddress
    state*: AddrState

  Verifier* = ref object of RootObj
    ## Tells the manager which candidates a remote peer reaches.

  ReachabilityChangeHandler* = proc(reachability: NetworkReachability): Future[void] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  AddressManagerConfig* = object
    maxSize*: int = DefaultObservedAddrMaxSize
    minCount*: int = DefaultObservedAddrMinCount
    verifyInterval*: Duration = DefaultVerifyInterval
      ## The time between two verification runs, and the time one run gets.

  SourcedMapper = object
    mapper: AddressMapper
    source: AddrSource

  AddressManager* = ref object of RootObj
    observations: seq[MultiAddress]
    candidates: OrderedTable[MultiAddress, AddrCandidate]
    mappers: seq[SourcedMapper]
    chainAddrs: Table[MultiAddress, set[AddrSource]]
    peerInfo: PeerInfo
    addressMapper: AddressMapper
    networkInterfaceProvider: NetworkInterfaceProvider
    verifier: Verifier
    verifyInterval: Duration
    verifyFut: Future[void]
    onReachabilityChange: ReachabilityChangeHandler
    notifiedReachability: NetworkReachability
    deriveIdentify: bool
    refutedGuesses: seq[MultiAddress]
    maxSize: int
    minCount: int
    started: bool

method verify*(
    self: Verifier, addresses: seq[MultiAddress]
): Future[seq[AddrVerdict]] {.base, async: (raises: [CancelledError]).} =
  ## One verdict per address the verifier concludes on. An address it leaves out
  ## keeps its state. The base verifier concludes nothing.
  @[]

func isStarted*(self: AddressManager): bool =
  self.started

proc isObservableIp(ip: IpAddress): bool =
  ## Loopback and private stay allowed: a peer on the same host or the same LAN
  ## does reach us there, and `PeerAddressPolicy` decides what is announced.
  case ip.family
  of IpAddressFamily.IPv4:
    # 224.0.0.0/4 is multicast, and everything above it is reserved
    ip.address_v4 != AnyAddress.address_v4 and ip.address_v4[0] < 224'u8
  of IpAddressFamily.IPv6:
    # ff00::/8 is multicast
    ip.address_v6 != AnyAddress6.address_v6 and ip.address_v6[0] != 0xff'u8

proc isRelayed(ma: MultiAddress): bool =
  ma.contains(multiCodec("p2p-circuit")).get(false)

proc isObservableAddr(ma: MultiAddress): bool =
  if not (ma.hasIp() and ma.hasTransport()) or ma.isRelayed():
    return false
  let ip = ma.getIp().valueOr:
    return false
  ip.isObservableIp()

proc addObservation*(self: AddressManager, observedAddr: MultiAddress): bool =
  ## Records the address a remote peer reports for us, evicting the oldest one
  ## past `maxSize`. False when the manager is stopped, or when no peer can have
  ## observed us on that address.
  if not self.started:
    return false

  # a remote peer picks what it reports: junk would only evict a useful entry
  if not observedAddr.isObservableAddr():
    return false

  if self.observations.len >= self.maxSize:
    self.observations.delete(0)
  self.observations.add(observedAddr)
  true

func firstProtoCode(ma: MultiAddress): MaResult[MultiCodec] =
  ma[0].flatMap(protoCode)

func mostObserved(
    self: AddressManager, observations: seq[MultiAddress], code: MultiCodec
): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  for ma, count in countTable.pairs:
    let maCode = ma.firstProtoCode().valueOr:
      continue
    if maCode == code and count >= self.minCount:
      return Opt.some(ma)
  Opt.none(MultiAddress)

func mostObservedIp(self: AddressManager, code: MultiCodec): Opt[MultiAddress] =
  var ips: seq[MultiAddress]
  for observation in self.observations:
    let ip = observation[0].valueOr:
      continue
    ips.add(ip)
  self.mostObserved(ips, code)

func mostObservedProtosAndPorts*(self: AddressManager): seq[MultiAddress] =
  ## The most observed IP4/Port and IP6/Port addresses, empty while no address
  ## reaches `minCount`.
  var res: seq[MultiAddress]
  self.mostObserved(self.observations, multiCodec("ip4")).withValue(ip4):
    res.add(ip4)
  self.mostObserved(self.observations, multiCodec("ip6")).withValue(ip6):
    res.add(ip6)
  res

func externalAddrFor*(self: AddressManager, listenAddr: MultiAddress): MultiAddress =
  ## Replaces the IP of a local listen address by the most observed IP of the
  ## same protocol, keeping the rest. Returns `listenAddr` while no IP of that
  ## protocol reaches `minCount`.
  let
    rest = listenAddr[1 ..^ 1].valueOr:
      return listenAddr
    code = listenAddr.firstProtoCode().valueOr:
      return listenAddr

  let observed = self.mostObservedIp(code).valueOr:
    return listenAddr

  concat(observed, rest).valueOr:
    listenAddr

func getMostObservedProtosAndPorts*(
    self: AddressManager
): seq[MultiAddress] {.deprecated: "use mostObservedProtosAndPorts".} =
  self.mostObservedProtosAndPorts()

func guessDialableAddr*(
    self: AddressManager, ma: MultiAddress
): MultiAddress {.deprecated: "use externalAddrFor".} =
  self.externalAddrFor(ma)

proc addSources(
    self: AddressManager,
    address: MultiAddress,
    sources: set[AddrSource],
    state: AddrState,
): bool {.discardable.} =
  let
    isNew = address notin self.candidates
    fresh = AddrCandidate(address: address, state: state)
  self.candidates.mgetOrPut(address, fresh).sources.incl(sources)
  isNew

proc add*(
    self: AddressManager,
    address: MultiAddress,
    source: AddrSource,
    state = AddrState.Unverified,
): bool {.discardable.} =
  ## Adds a candidate, or adds `source` to the producers of the one already under
  ## `address`, keeping the state a verifier assigned. True for a new candidate.
  self.addSources(address, {source}, state)

proc update*(
    self: AddressManager, address: MultiAddress, state: AddrState
): bool {.discardable.} =
  if address notin self.candidates:
    return false
  self.candidates.mgetOrPut(address, AddrCandidate()).state = state
  true

proc remove*(self: AddressManager, address: MultiAddress): bool {.discardable.} =
  if address notin self.candidates:
    return false
  self.candidates.del(address)
  true

func candidates*(self: AddressManager): seq[AddrCandidate] =
  toSeq(self.candidates.values)

func confirmedAddrs*(self: AddressManager): seq[MultiAddress] =
  ## The addresses a verifier confirmed. Empty while no verifier runs.
  toSeq(self.candidates.values).filterIt(it.state == AddrState.Confirmed).mapIt(
    it.address
  )

func reachability*(self: AddressManager): NetworkReachability =
  ## Read-only summary of the per-address states: any Confirmed wins, else any Unreachable.
  var summary = NetworkReachability.Unknown
  for candidate in self.candidates.values:
    case candidate.state
    of AddrState.Confirmed:
      return NetworkReachability.Reachable
    of AddrState.Unreachable:
      summary = NetworkReachability.NotReachable
    of AddrState.Unverified:
      discard
  summary

proc `onReachabilityChange=`*(
    self: AddressManager, handler: ReachabilityChangeHandler
) =
  ## Called after a verification run which changes the `reachability` summary; one slot.
  self.onReachabilityChange = handler

proc `deriveIdentifyCandidates=`*(self: AddressManager, enabled: bool) =
  ## Each verification run then turns the identify observations into `Identify` candidates.
  self.deriveIdentify = enabled

func notFromMappers(self: AddressManager, address: MultiAddress): bool =
  address notin self.chainAddrs

proc addMapper*(self: AddressManager, mapper: AddressMapper, source: AddrSource) =
  ## Each address this mapper adds becomes a candidate of `source`. `stop` drops
  ## every mapper: an owner registers its own again on `start`.
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
  ## A nil provider announces the wildcard listen addresses as they are.
  self.networkInterfaceProvider = provider

func isLoopbackOrUp(networkInterface: NetworkInterface): bool =
  networkInterface.ifType == IfSoftwareLoopback or networkInterface.state == StatusUp

proc getAddresses*(addrFamily: AddressFamily): seq[InterfaceAddress] =
  ## The addresses of every loopback or running interface of `addrFamily`.
  let interfaces = getInterfaces().filterIt(it.isLoopbackOrUp())
  concat(interfaces.mapIt(it.addresses)).filterIt(it.host.family == addrFamily)

proc isWildcardIp(ip: IpAddress): bool =
  case ip.family
  of IpAddressFamily.IPv4:
    ip.address_v4 == AnyAddress.address_v4
  of IpAddressFamily.IPv6:
    ip.address_v6 == AnyAddress6.address_v6

proc expandWildcardAddresses*(
    networkInterfaceProvider: NetworkInterfaceProvider, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  ## Expands each bound wildcard address (``0.0.0.0`` / ``::``) into one address
  ## per matching network interface, keeping the port and any suffix (e.g.
  ## ``/quic-v1``, ``/ws``, ``/tls/ws``). The others pass through unchanged.
  var addresses: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let listenIp = listenAddr.getIp().valueOr:
      addresses.add(listenAddr)
      continue

    if not isWildcardIp(listenIp):
      addresses.add(listenAddr)
      continue

    let families =
      case listenIp.family
      of IpAddressFamily.IPv4:
        @[AddressFamily.IPv4]
      of IpAddressFamily.IPv6:
        # IPv6 dual stack: also expand to IPv4 interfaces
        @[AddressFamily.IPv6, AddressFamily.IPv4]

    for family in families:
      for ifaddr in networkInterfaceProvider(family):
        listenAddr.replaceIp(ifaddr.host.toIpAddress()).withValue(remapped):
          addresses.add(remapped)
  addresses

proc expandWildcards(
    self: AddressManager, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  if self.networkInterfaceProvider.isNil():
    return listenAddrs
  expandWildcardAddresses(self.networkInterfaceProvider, listenAddrs)

proc withdraw(self: AddressManager, produced: Table[MultiAddress, set[AddrSource]]) =
  ## Drops every chain source which no longer produces its address, e.g. an
  ## expired NAT mapping or a lost relay reservation. A candidate goes with its
  ## last source, so one another producer still offers stays.
  for address, sources in self.chainAddrs:
    let gone = sources - produced.getOrDefault(address)
    if gone == {}:
      continue
    var candidate = self.candidates.getOrDefault(address)
    candidate.sources.excl(gone)
    if candidate.sources == {}:
      self.candidates.del(address)
    else:
      self.candidates[address] = candidate

proc track(
    self: AddressManager,
    produced: Table[MultiAddress, set[AddrSource]],
    kept: seq[MultiAddress],
) =
  ## Makes each address the chain still produces a candidate of the sources which
  ## produced it, and withdraws the chain sources of the ones it dropped.
  var chainAddrs: Table[MultiAddress, set[AddrSource]]
  for address in kept:
    let sources = produced.getOrDefault(address)
    self.addSources(address, sources, AddrState.Unverified)
    chainAddrs[address] = sources

  self.withdraw(chainAddrs)
  self.chainAddrs = chainAddrs

func isAnnounceable(self: AddressManager, address: MultiAddress): bool =
  ## An observation-derived guess is remote input: it announces only once confirmed.
  let candidate = self.candidates.getOrDefault(address)
  case candidate.state
  of AddrState.Unreachable:
    false
  of AddrState.Confirmed:
    true
  of AddrState.Unverified:
    candidate.sources != {AddrSource.Identify}

func announceSet(
    self: AddressManager, mappedAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  ## Every confirmed or unverified candidate; a verified-unreachable one stays out.
  var res: seq[MultiAddress]
  for address in mappedAddrs:
    if self.isAnnounceable(address) and address notin res:
      res.add(address)
  for address in self.candidates.keys:
    if self.notFromMappers(address) and address notin res and
        self.isAnnounceable(address):
      res.add(address)
  res

func explicitAddrs(self: AddressManager): seq[MultiAddress] =
  if self.peerInfo.isNil():
    return @[]
  self.peerInfo.announcedAddrs

proc resolve(
    self: AddressManager, inputAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  let announced = self.explicitAddrs()
  var
    addrs = self.expandWildcards(inputAddrs)
    produced: Table[MultiAddress, set[AddrSource]]

  for address in addrs:
    produced.mgetOrPut(address, {}).incl(AddrSource.Listen)

  for sourced in self.mappers:
    let mapped = await sourced.mapper(addrs)
    for address in mapped.filterIt(it notin addrs):
      produced.mgetOrPut(address, {}).incl(sourced.source)
    addrs = mapped

  for address in announced:
    produced.mgetOrPut(address, {}).incl(AddrSource.Announced)

  self.track(produced, addrs & announced)

  # the operator picks what is announced; no mapper rewrites that choice
  if announced.len > 0:
    return announced

  self.announceSet(addrs)

proc resolveMapper(self: AddressManager): AddressMapper =
  ## Built here, not inside `new`: `new` is generic over its `typedesc`, so an
  ## async closure in its body is re-expanded at every instantiation site and
  ## fails in modules which lack the chronos internals.
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    await self.resolve(listenAddrs)

func identifyGuesses(self: AddressManager): seq[MultiAddress] =
  ## Listen addresses with the most observed IP, and the most observed proto/ports.
  var guesses: seq[MultiAddress]
  for listenAddr in self.peerInfo.listenAddrs:
    let guessed = self.externalAddrFor(listenAddr)
    if guessed != listenAddr:
      guesses.add(guessed)
  guesses & self.mostObservedProtosAndPorts()

proc addIdentifyCandidates(self: AddressManager) =
  if not self.deriveIdentify or self.peerInfo.isNil():
    return
  for guess in self.identifyGuesses().filterIt(it notin self.refutedGuesses):
    self.add(guess, AddrSource.Identify)

proc rememberRefuted(self: AddressManager, address: MultiAddress) =
  ## A wrongly refuted guess returns only through ring eviction or a restart.
  if self.refutedGuesses.len >= self.maxSize:
    self.refutedGuesses.delete(0)
  self.refutedGuesses.add(address)

proc applyVerdicts(self: AddressManager, verdicts: seq[AddrVerdict]): bool =
  ## True when a state changed. One random peer decides a verdict; later runs heal it.
  var changed = false
  for verdict in verdicts:
    if verdict.address notin self.candidates:
      continue
    let candidate = self.candidates.getOrDefault(verdict.address)
    # a refuted guess is dropped, or an attacker could grow the table without cap
    if verdict.state == AddrState.Unreachable and
        candidate.sources == {AddrSource.Identify}:
      self.remove(verdict.address)
      self.rememberRefuted(verdict.address)
      changed = true
    elif candidate.state != verdict.state:
      self.update(verdict.address, verdict.state)
      changed = true
  changed

proc notifyReachability(self: AddressManager) {.async: (raises: [CancelledError]).} =
  let summary = self.reachability()
  if summary == self.notifiedReachability:
    return
  self.notifiedReachability = summary
  if not self.onReachabilityChange.isNil():
    await self.onReachabilityChange(summary)

proc allowedByPolicy(self: AddressManager, address: MultiAddress): bool =
  ## The policy gates the dial requests too: a banned address never reaches a verifier.
  self.peerInfo.isNil() or self.peerInfo.addressPolicy.accepts(address)

proc verifyCandidates(self: AddressManager) {.async: (raises: [CancelledError]).} =
  if self.verifier.isNil():
    return
  self.addIdentifyCandidates()

  # a relayed candidate stays unverified: no AutoNAT peer dials a circuit address back
  let addresses = toSeq(self.candidates.keys).filterIt(
      not it.isRelayed() and self.allowedByPolicy(it)
    )
  if addresses.len == 0:
    return

  # one run fits in one interval, so a slow verifier delays no other run
  let verdicts =
    try:
      await self.verifier.verify(addresses).wait(self.verifyInterval)
    except AsyncTimeoutError:
      debug "Verifier ran out of time", interval = self.verifyInterval
      return

  if not self.applyVerdicts(verdicts):
    return
  if not self.peerInfo.isNil():
    await self.peerInfo.update()
  await self.notifyReachability()

proc verifyHeartbeat(self: AddressManager) {.async: (raises: [CancelledError]).} =
  heartbeat "AddressManager candidate verification", self.verifyInterval:
    await self.verifyCandidates()

proc restartHeartbeat(self: AddressManager) =
  ## A sleeping heartbeat holds its old wake-up time; the restart applies changes now.
  if not self.started:
    return
  if not self.verifyFut.isNil():
    self.verifyFut.cancelSoon()
  self.verifyFut = self.verifyHeartbeat()

proc `verifier=`*(self: AddressManager, verifier: Verifier) =
  ## The verifier is optional. Without one, every candidate stays `Unverified`.
  self.verifier = verifier
  self.restartHeartbeat()

proc `verifyInterval=`*(self: AddressManager, interval: Duration) =
  self.verifyInterval = max(interval, 1.milliseconds)
  self.restartHeartbeat()

proc start*(self: AddressManager, peerInfo: PeerInfo = nil) =
  ## With a `PeerInfo`, installs the manager's mapper as the first one it runs.
  if self.started:
    return
  self.started = true
  self.verifyFut = self.verifyHeartbeat()

  if peerInfo.isNil():
    return
  self.peerInfo = peerInfo
  peerInfo.addressMappers.insert(self.addressMapper, 0)

proc stop*(self: AddressManager) =
  self.started = false
  if not self.verifyFut.isNil():
    self.verifyFut.cancelSoon()
    self.verifyFut = nil
  self.observations.setLen(0)
  self.candidates.clear()
  self.chainAddrs.clear()
  self.mappers.setLen(0)
  self.onReachabilityChange = nil
  self.notifiedReachability = NetworkReachability.Unknown
  self.refutedGuesses.setLen(0)

  if self.peerInfo.isNil():
    return
  self.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  self.peerInfo = nil

func `$`*(self: AddressManager): string =
  let addresses = toSeq(self.candidates.keys)
  "observations: " & $self.observations & ", candidates: " & $addresses

proc new*(
    T: typedesc[AddressManager], config: AddressManagerConfig = AddressManagerConfig()
): T =
  ## A threshold below one is raised to one: a minCount of zero would let a
  ## single peer decide the external address.
  let manager = T(
    maxSize: max(config.maxSize, 1),
    minCount: max(config.minCount, 1),
    verifyInterval: max(config.verifyInterval, 1.milliseconds),
  )
  manager.addressMapper = manager.resolveMapper()
  manager
