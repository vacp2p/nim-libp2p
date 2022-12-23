# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, deques, sequtils]
import chronos, metrics
import ../switch
import ../protocols/[connectivity/autonat]
import ../utils/heartbeat
import ../crypto/crypto

declarePublicGauge(libp2p_autonat_reachability_confidence, "autonat reachability confidence", labels = ["reachability"])

type
  AutonatService* = ref object of Service
    newConnectedPeerHandler: PeerEventHandler
    scheduleHandle: Future[void]
    networkReachability: NetworkReachability
    confidence: Option[float]
    answers: Deque[NetworkReachability]
    autonat: Autonat
    statusAndConfidenceHandler: StatusAndConfidenceHandler
    rng: ref HmacDrbgContext
    scheduleInterval: Option[Duration]
    askNewConnectedPeers: bool
    numPeersToAsk: int
    maxQueueSize: int
    minConfidence: float
    dialTimeout: Duration

  NetworkReachability* {.pure.} = enum
    NotReachable, Reachable, Unknown

  StatusAndConfidenceHandler* = proc (networkReachability: NetworkReachability, confidence: Option[float]): Future[void]  {.gcsafe, raises: [Defect].}

proc new*(
  T: typedesc[AutonatService],
  autonat: Autonat,
  rng: ref HmacDrbgContext,
  scheduleInterval: Option[Duration] = none(Duration),
  askNewConnectedPeers = true,
  numPeersToAsk: int = 5,
  maxQueueSize: int = 10,
  minConfidence: float = 0.3,
  dialTimeout = 30.seconds): T =
  return T(
    scheduleInterval: scheduleInterval,
    networkReachability: Unknown,
    confidence: none(float),
    answers: initDeque[NetworkReachability](),
    autonat: autonat,
    rng: rng,
    askNewConnectedPeers: askNewConnectedPeers,
    numPeersToAsk: numPeersToAsk,
    maxQueueSize: maxQueueSize,
    minConfidence: minConfidence,
    dialTimeout: dialTimeout)

proc networkReachability*(self: AutonatService): NetworkReachability {.inline.} =
  return self.networkReachability

proc callHandler(self: AutonatService) {.async.} =
  if not isNil(self.statusAndConfidenceHandler):
    await self.statusAndConfidenceHandler(self.networkReachability, self.confidence)

proc handleAnswer(self: AutonatService, ans: NetworkReachability) {.async.} =

  if ans == Unknown:
    return

  if self.answers.len == self.maxQueueSize:
      self.answers.popFirst()
  self.answers.addLast(ans)

  self.networkReachability = Unknown
  self.confidence = none(float)
  const reachabilityPriority = [Reachable, NotReachable]
  for reachability in reachabilityPriority:
    let confidence = self.answers.countIt(it == reachability) / self.maxQueueSize
    libp2p_autonat_reachability_confidence.set(value = confidence, labelValues = [$reachability])
    if self.confidence.isNone and confidence >= self.minConfidence:
      self.networkReachability = reachability
      self.confidence = some(confidence)

  trace "Current status", currentStats = $self.networkReachability, confidence = $self.confidence

proc askPeer(self: AutonatService, s: Switch, peerId: PeerId): Future[NetworkReachability] {.async.} =
  trace "Asking for reachability", peerId = $peerId
  let ans =
    try:
      discard await self.autonat.dialMe(peerId).wait(self.dialTimeout)
      Reachable
    except AutonatUnreachableError:
      trace "dialMe answer is not reachable", peerId = $peerId
      NotReachable
    except AsyncTimeoutError:
      trace "dialMe timed out", peerId = $peerId
      Unknown
    except CatchableError as err:
      trace "dialMe unexpected error", peerId = $peerId, errMsg = $err.msg
      Unknown
  await self.handleAnswer(ans)
  if not isNil(self.statusAndConfidenceHandler):
    await self.statusAndConfidenceHandler(self.networkReachability, self.confidence)
  return ans

proc askConnectedPeers(self: AutonatService, switch: Switch) {.async.} =
  var peers = switch.connectedPeers(Direction.Out)
  self.rng.shuffle(peers)
  var answersFromPeers = 0
  for peer in peers:
    if answersFromPeers >= self.numPeersToAsk:
      break
    elif (await askPeer(self, switch, peer)) != Unknown:
      answersFromPeers.inc()

proc schedule(service: AutonatService, switch: Switch, interval: Duration) {.async.} =
  heartbeat "Schedule AutonatService run", interval:
    await service.run(switch)

method setup*(self: AutonatService, switch: Switch): Future[bool] {.async.} =
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    if self.askNewConnectedPeers:
      self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] {.async.} =
        discard askPeer(self, switch, peerId)
        await self.callHandler()
      switch.connManager.addPeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
    if self.scheduleInterval.isSome():
      self.scheduleHandle = schedule(self, switch, self.scheduleInterval.get())
  return hasBeenSetup

method run*(self: AutonatService, switch: Switch) {.async, public.} =
  await askConnectedPeers(self, switch)
  await self.callHandler()


method stop*(self: AutonatService, switch: Switch): Future[bool] {.async, public.} =
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    if not isNil(self.scheduleHandle):
      self.scheduleHandle.cancel()
      self.scheduleHandle = nil
    if not isNil(self.newConnectedPeerHandler):
      switch.connManager.removePeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
  return hasBeenStopped

proc statusAndConfidenceHandler*(self: AutonatService, statusAndConfidenceHandler: StatusAndConfidenceHandler) =
  self.statusAndConfidenceHandler = statusAndConfidenceHandler
