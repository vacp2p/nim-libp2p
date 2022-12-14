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
    answerDeque: Deque[NetworkReachability]
    autonat: Autonat
    statusAndConfidenceHandler: StatusAndConfidenceHandler
    rng: ref HmacDrbgContext
    scheduleInterval: Option[Duration]
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
  numPeersToAsk: int = 5,
  maxQueueSize: int = 10,
  minConfidence: float = 0.3,
  dialTimeout = 5.seconds): T =
  return T(
    scheduleInterval: scheduleInterval,
    networkReachability: NetworkReachability.Unknown,
    confidence: none(float),
    answerDeque: initDeque[NetworkReachability](),
    autonat: autonat,
    rng: rng,
    numPeersToAsk: numPeersToAsk,
    maxQueueSize: maxQueueSize,
    minConfidence: minConfidence,
    dialTimeout: dialTimeout)

proc networkReachability*(self: AutonatService): NetworkReachability {.inline.} =
  return self.networkReachability

proc handleAnswer(self: AutonatService, ans: NetworkReachability) {.async.} =

  if self.answerDeque.len == self.maxQueueSize:
    self.answerDeque.popFirst()

  self.answerDeque.addLast(ans)

  let reachableCount = toSeq(self.answerDeque.items).countIt(it == NetworkReachability.Reachable)
  let confidence = reachableCount / self.maxQueueSize
  if confidence >= self.minConfidence:
    self.networkReachability = NetworkReachability.Reachable
    self.confidence = some(confidence)
    libp2p_autonat_reachability_confidence.set(value = confidence, labelValues = ["Reachable"])
  else:
    let notReachableCount = toSeq(self.answerDeque.items).countIt(it == NetworkReachability.NotReachable)
    let confidence = notReachableCount / self.maxQueueSize
    if confidence >= self.minConfidence:
      self.networkReachability = NetworkReachability.NotReachable
      self.confidence = some(confidence)
      libp2p_autonat_reachability_confidence.set(confidence, ["NotReachable"])
    else:
      self.networkReachability = NetworkReachability.Unknown
      self.confidence = none(float)

  if not isNil(self.statusAndConfidenceHandler):
    await self.statusAndConfidenceHandler(self.networkReachability, self.confidence)

  trace "Current status", currentStats = $self.networkReachability, confidence = $self.confidence

proc askPeer(self: AutonatService, s: Switch, peerId: PeerId): Future[NetworkReachability] {.async.} =
  trace "Asking for reachability", peerId = $peerId
  let ans =
    try:
      discard await self.autonat.dialMe(peerId).wait(self.dialTimeout)
      NetworkReachability.Reachable
    except AutonatUnreachableError:
      trace "dialMe answer is not reachable", peerId = $peerId
      NetworkReachability.NotReachable
    except AsyncTimeoutError:
      trace "dialMe timed out", peerId = $peerId
      NetworkReachability.Unknown
    except CatchableError as err:
      trace "dialMe unexpected error", peerId = $peerId, errMsg = $err.msg
      NetworkReachability.Unknown
  await self.handleAnswer(ans)
  return ans

proc askConnectedPeers(self: AutonatService, switch: Switch) {.async.} =
  var peers = switch.connectedPeers(Direction.Out)
  self.rng.shuffle(peers)
  var answersFromPeers = 0
  for peer in peers:
    if answersFromPeers >= self.numPeersToAsk:
      break
    elif (await askPeer(self, switch, peer)) != NetworkReachability.Unknown:
      answersFromPeers.inc()

proc schedule(service: AutonatService, switch: Switch, interval: Duration) {.async.} =
  heartbeat "Schedule AutonatService run", interval:
    await service.run(switch)

method setup*(self: AutonatService, switch: Switch): Future[bool] {.async.} =
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] {.async.} =
      discard askPeer(self, switch, peerId)
    switch.connManager.addPeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
    if self.scheduleInterval.isSome():
      self.scheduleHandle = schedule(self, switch, self.scheduleInterval.get())
  return hasBeenSetup

method run*(self: AutonatService, switch: Switch) {.async, public.} =
  await askConnectedPeers(self, switch)

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
