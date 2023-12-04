# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[deques, sequtils]
import chronos, metrics
import ../../../switch
import ../../../wire
import client
from core import NetworkReachability, AutonatUnreachableError
import ../../../utils/heartbeat
import ../../../crypto/crypto

export core.NetworkReachability

logScope:
  topics = "libp2p autonatservice"

declarePublicGauge(libp2p_autonat_reachability_confidence, "autonat reachability confidence", labels = ["reachability"])

type
  AutonatService* = ref object of Service
    newConnectedPeerHandler: PeerEventHandler
    addressMapper: AddressMapper
    scheduleHandle: Future[void]
    networkReachability*: NetworkReachability
    confidence: Opt[float]
    answers: Deque[NetworkReachability]
    autonatClient: AutonatClient
    statusAndConfidenceHandler: StatusAndConfidenceHandler
    rng: ref HmacDrbgContext
    scheduleInterval: Opt[Duration]
    askNewConnectedPeers: bool
    numPeersToAsk: int
    maxQueueSize: int
    minConfidence: float
    dialTimeout: Duration
    enableAddressMapper: bool

  StatusAndConfidenceHandler* = proc (networkReachability: NetworkReachability, confidence: Opt[float]): Future[void]  {.gcsafe, raises: [].}

proc new*(
  T: typedesc[AutonatService],
  autonatClient: AutonatClient,
  rng: ref HmacDrbgContext,
  scheduleInterval: Opt[Duration] = Opt.none(Duration),
  askNewConnectedPeers = true,
  numPeersToAsk: int = 5,
  maxQueueSize: int = 10,
  minConfidence: float = 0.3,
  dialTimeout = 30.seconds,
  enableAddressMapper = true): T =
  return T(
    scheduleInterval: scheduleInterval,
    networkReachability: Unknown,
    confidence: Opt.none(float),
    answers: initDeque[NetworkReachability](),
    autonatClient: autonatClient,
    rng: rng,
    askNewConnectedPeers: askNewConnectedPeers,
    numPeersToAsk: numPeersToAsk,
    maxQueueSize: maxQueueSize,
    minConfidence: minConfidence,
    dialTimeout: dialTimeout,
    enableAddressMapper: enableAddressMapper)

proc callHandler(self: AutonatService) {.async.} =
  if not isNil(self.statusAndConfidenceHandler):
    await self.statusAndConfidenceHandler(self.networkReachability, self.confidence)

proc hasEnoughIncomingSlots(switch: Switch): bool =
  # we leave some margin instead of comparing to 0 as a peer could connect to us while we are asking for the dial back
  return switch.connManager.slotsAvailable(In) >= 2

proc doesPeerHaveIncomingConn(switch: Switch, peerId: PeerId): bool =
  return switch.connManager.selectMuxer(peerId, In) != nil

proc handleAnswer(self: AutonatService, ans: NetworkReachability): Future[bool] {.async.} =

  if ans == Unknown:
    return

  let oldNetworkReachability = self.networkReachability
  let oldConfidence = self.confidence

  if self.answers.len == self.maxQueueSize:
    self.answers.popFirst()
  self.answers.addLast(ans)

  self.networkReachability = Unknown
  self.confidence = Opt.none(float)
  const reachabilityPriority = [Reachable, NotReachable]
  for reachability in reachabilityPriority:
    let confidence = self.answers.countIt(it == reachability) / self.maxQueueSize
    libp2p_autonat_reachability_confidence.set(value = confidence, labelValues = [$reachability])
    if self.confidence.isNone and confidence >= self.minConfidence:
      self.networkReachability = reachability
      self.confidence = Opt.some(confidence)

  debug "Current status", currentStats = $self.networkReachability, confidence = $self.confidence, answers = self.answers

  # Return whether anything has changed
  return self.networkReachability != oldNetworkReachability or self.confidence != oldConfidence

proc askPeer(self: AutonatService, switch: Switch, peerId: PeerId): Future[NetworkReachability] {.async.} =
  logScope:
    peerId = $peerId

  if doesPeerHaveIncomingConn(switch, peerId):
    return Unknown

  if not hasEnoughIncomingSlots(switch):
    debug "No incoming slots available, not asking peer", incomingSlotsAvailable=switch.connManager.slotsAvailable(In)
    return Unknown

  trace "Asking peer for reachability"
  let ans =
    try:
      discard await self.autonatClient.dialMe(switch, peerId).wait(self.dialTimeout)
      debug "dialMe answer is reachable"
      Reachable
    except AutonatUnreachableError as error:
      debug "dialMe answer is not reachable", msg = error.msg
      NotReachable
    except AsyncTimeoutError as error:
      debug "dialMe timed out", msg = error.msg
      Unknown
    except CatchableError as error:
      debug "dialMe unexpected error", msg = error.msg
      Unknown
  let hasReachabilityOrConfidenceChanged = await self.handleAnswer(ans)
  if hasReachabilityOrConfidenceChanged:
    await self.callHandler()
  await switch.peerInfo.update()
  return ans

proc askConnectedPeers(self: AutonatService, switch: Switch) {.async.} =
  trace "Asking peers for reachability"
  var peers = switch.connectedPeers(Direction.Out)
  self.rng.shuffle(peers)
  var answersFromPeers = 0
  for peer in peers:
    if answersFromPeers >= self.numPeersToAsk:
      break
    if not hasEnoughIncomingSlots(switch):
      debug "No incoming slots available, not asking peers", incomingSlotsAvailable=switch.connManager.slotsAvailable(In)
      break
    if (await askPeer(self, switch, peer)) != Unknown:
      answersFromPeers.inc()

proc schedule(service: AutonatService, switch: Switch, interval: Duration) {.async.} =
  heartbeat "Scheduling AutonatService run", interval:
    await service.run(switch)

proc addressMapper(
  self: AutonatService,
  peerStore: PeerStore,
  listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =

  if self.networkReachability != NetworkReachability.Reachable:
    return listenAddrs

  var addrs = newSeq[MultiAddress]()
  for listenAddr in listenAddrs:
    var processedMA = listenAddr
    try:
      if not listenAddr.isPublicMA() and self.networkReachability == NetworkReachability.Reachable:
        processedMA = peerStore.guessDialableAddr(listenAddr) # handle manual port forwarding
    except CatchableError as exc:
      debug "Error while handling address mapper", msg = exc.msg
    addrs.add(processedMA)
  return addrs

method setup*(self: AutonatService, switch: Switch): Future[bool] {.async.} =
  self.addressMapper = proc (listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
    return await addressMapper(self, switch.peerStore, listenAddrs)

  info "Setting up AutonatService"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    if self.askNewConnectedPeers:
      self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] {.async.} =
        discard askPeer(self, switch, peerId)
      switch.connManager.addPeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
    self.scheduleInterval.withValue(interval):
      self.scheduleHandle = schedule(self, switch, interval)
    if self.enableAddressMapper:
      switch.peerInfo.addressMappers.add(self.addressMapper)
  return hasBeenSetup

method run*(self: AutonatService, switch: Switch) {.async, public.} =
  trace "Running AutonatService"
  await askConnectedPeers(self, switch)

method stop*(self: AutonatService, switch: Switch): Future[bool] {.async, public.} =
  info "Stopping AutonatService"
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    if not isNil(self.scheduleHandle):
      self.scheduleHandle.cancel()
      self.scheduleHandle = nil
    if not isNil(self.newConnectedPeerHandler):
      switch.connManager.removePeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
    if self.enableAddressMapper:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    await switch.peerInfo.update()
  return hasBeenStopped

proc statusAndConfidenceHandler*(self: AutonatService, statusAndConfidenceHandler: StatusAndConfidenceHandler) =
  self.statusAndConfidenceHandler = statusAndConfidenceHandler
