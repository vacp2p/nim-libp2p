# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[deques, sequtils]
import chronos, metrics
import ../../../switch
import ../../../wire
import client
from types import NetworkReachability, AutonatUnreachableError
import ../../../utils/[heartbeat, future]
import ../../../crypto/crypto

export NetworkReachability

logScope:
  topics = "libp2p autonatservice"

declarePublicGauge(
  libp2p_autonat_reachability_confidence,
  "autonat reachability confidence",
  labels = ["reachability"],
)

type
  AutonatService* = ref object of ReachabilityService
    newConnectedPeerHandler: PeerEventHandler
    addressMapper: AddressMapper
    scheduleHandle: Future[void]
    networkReachability*: NetworkReachability
    confidence: Opt[float]
    answers: Deque[NetworkReachability]
    autonatClient: AutonatClient
    subscribers: Subscribers[StatusAndConfidenceHandler]
    rng: Rng
    scheduleInterval: Opt[Duration]
    askNewConnectedPeers: bool
    numPeersToAsk: int
    maxQueueSize: int
    minConfidence: float
    dialTimeout: Duration
    enableAddressMapper: bool

  StatusAndConfidenceHandler* = proc(
    networkReachability: NetworkReachability, confidence: Opt[float]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

proc new*(
    T: typedesc[AutonatService],
    autonatClient: AutonatClient,
    rng: Rng,
    scheduleInterval: Opt[Duration] = Opt.none(Duration),
    askNewConnectedPeers = true,
    numPeersToAsk: int = 5,
    maxQueueSize: int = 10,
    minConfidence: float = 0.3,
    dialTimeout = 30.seconds,
    enableAddressMapper = true,
): T =
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
    enableAddressMapper: enableAddressMapper,
  )

proc callHandler(self: AutonatService) {.async: (raises: [CancelledError]).} =
  # Handlers start in subscription order, then run concurrently, so a subscriber
  # that blocks does not delay the subscribers behind it.
  await allOrCancel(
    self.subscribers.handlers.mapIt(it(self.networkReachability, self.confidence))
  )

proc hasEnoughIncomingSlots(switch: Switch): bool =
  # we leave some margin instead of comparing to 0 as a peer could connect to us while we are asking for the dial back
  return switch.connManager.availableSlots(In) >= 2

proc doesPeerHaveIncomingConn(switch: Switch, peerId: PeerId): bool =
  return switch.connManager.selectMuxer(peerId, In) != nil

proc handleAnswer(
    self: AutonatService, ans: NetworkReachability
): Future[bool] {.async: (raises: [CancelledError]).} =
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
    libp2p_autonat_reachability_confidence.set(
      value = confidence, labelValues = [$reachability]
    )
    if self.confidence.isNone and confidence >= self.minConfidence:
      self.networkReachability = reachability
      self.confidence = Opt.some(confidence)

  debug "Current status",
    currentStats = $self.networkReachability,
    confidence = $self.confidence,
    answers = self.answers

  # Return whether anything has changed
  return
    self.networkReachability != oldNetworkReachability or
    self.confidence != oldConfidence

proc askPeer(
    self: AutonatService, switch: Switch, peerId: PeerId
): Future[NetworkReachability] {.async: (raises: [CancelledError]).} =
  logScope:
    peerId = $peerId

  if doesPeerHaveIncomingConn(switch, peerId):
    return Unknown

  if not hasEnoughIncomingSlots(switch):
    debug "No incoming slots available, not asking peer",
      incomingSlotsAvailable = switch.connManager.availableSlots(In)
    return Unknown

  trace "Asking peer for reachability"
  let ans =
    try:
      discard await self.autonatClient.dialMe(switch, peerId).wait(self.dialTimeout)
      debug "dialMe answer is reachable"
      Reachable
    except AutonatUnreachableError as error:
      debug "dialMe answer is not reachable", description = error.msg
      NotReachable
    except AsyncTimeoutError as error:
      debug "dialMe timed out", description = error.msg
      Unknown
    except CancelledError as error:
      raise error
    except CatchableError as error:
      debug "dialMe unexpected error", description = error.msg
      Unknown
  let hasReachabilityOrConfidenceChanged = await self.handleAnswer(ans)
  if hasReachabilityOrConfidenceChanged:
    await self.callHandler()
  await switch.peerInfo.update()
  return ans

proc askConnectedPeers(
    self: AutonatService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Asking peers for reachability"
  var peers = switch.connectedPeers(Direction.Out)
  self.rng.shuffle(peers)
  var answersFromPeers = 0
  for peer in peers:
    if answersFromPeers >= self.numPeersToAsk:
      break
    if not hasEnoughIncomingSlots(switch):
      debug "No incoming slots available, not asking peers",
        incomingSlotsAvailable = switch.connManager.availableSlots(In)
      break
    if (await askPeer(self, switch, peer)) != Unknown:
      answersFromPeers.inc()

proc schedule(
    service: AutonatService, switch: Switch, interval: Duration
) {.async: (raises: [CancelledError]).} =
  heartbeat "Scheduling AutonatService run", interval:
    await service.askConnectedPeers(switch)

proc addressMapper(
    self: AutonatService, peerStore: PeerStore, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  if self.networkReachability != NetworkReachability.Reachable:
    return listenAddrs

  var addrs = newSeq[MultiAddress]()
  for listenAddr in listenAddrs:
    var processedMA = listenAddr
    try:
      if not listenAddr.isPublicMA() and
          self.networkReachability == NetworkReachability.Reachable:
        processedMA = peerStore.guessDialableAddr(listenAddr)
          # handle manual port forwarding
    except CatchableError as exc:
      debug "Error while handling address mapper", description = exc.msg
    addrs.add(processedMA)
  return addrs

method setup*(self: AutonatService, switch: Switch) {.raises: [].} =
  info "Setting up AutonatService"

  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    return await addressMapper(self, switch.peerStore, listenAddrs)

  if self.askNewConnectedPeers:
    self.newConnectedPeerHandler = proc(
        peerId: PeerId, event: PeerEvent
    ): Future[void] {.async: (raises: [CancelledError]).} =
      discard askPeer(self, switch, peerId)

method start*(
    self: AutonatService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Running AutonatService"

  switch.connManager.addPeerEventHandler(
    self.newConnectedPeerHandler, PeerEventKind.Joined
  )

  if self.enableAddressMapper:
    switch.peerInfo.addressMappers.add(self.addressMapper)
    await switch.peerInfo.update()

  self.scheduleInterval.withValue(interval):
    if self.scheduleHandle.isNil:
      self.scheduleHandle = schedule(self, switch, interval)

method stop*(
    self: AutonatService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  info "Stopping AutonatService"
  if not isNil(self.scheduleHandle):
    self.scheduleHandle.cancelSoon()
    self.scheduleHandle = nil
  if not isNil(self.newConnectedPeerHandler):
    switch.connManager.removePeerEventHandler(
      self.newConnectedPeerHandler, PeerEventKind.Joined
    )
  if self.enableAddressMapper:
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  await switch.peerInfo.update()

proc addStatusAndConfidenceHandler*(
    self: AutonatService, handler: StatusAndConfidenceHandler
): SubscriptionId {.discardable.} =
  self.subscribers.subscribe(handler)

proc removeStatusAndConfidenceHandler*(self: AutonatService, id: SubscriptionId): bool =
  self.subscribers.unsubscribe(id)

proc statusAndConfidenceHandler*(
    self: AutonatService, handler: StatusAndConfidenceHandler
) {.deprecated: "use addStatusAndConfidenceHandler; it appends, it does not replace".} =
  self.addStatusAndConfidenceHandler(handler)

method addReachabilityHandler*(
    self: AutonatService, handler: ReachabilityHandler
): SubscriptionId {.discardable.} =
  if handler.isNil():
    return NoSubscription
  self.addStatusAndConfidenceHandler(
    proc(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      await handler(networkReachability)
  )

method removeReachabilityHandler*(self: AutonatService, id: SubscriptionId): bool =
  self.removeStatusAndConfidenceHandler(id)

method networkReachability*(self: AutonatService): NetworkReachability =
  self.networkReachability
