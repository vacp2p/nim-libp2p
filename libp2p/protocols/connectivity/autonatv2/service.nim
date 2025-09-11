# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[deques, sequtils]
import chronos, chronicles, metrics, results
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
  ../../../protobuf/minprotobuf,
  ../../../wire,
  ../../../utils/heartbeat,
  ../../../crypto/crypto,
  ../autonat/types,
  ./types,
  ./client

declarePublicGauge(
  libp2p_autonat_v2_reachability_confidence,
  "autonat v2 reachability confidence",
  labels = ["reachability"],
)

logScope:
  topics = "libp2p autonatv2 service"

type
  AutonatV2ServiceConfig* = object
    scheduleInterval: Opt[Duration]
    askNewConnectedPeers: bool
    numPeersToAsk: int
    maxQueueSize: int
    minConfidence: float
    enableAddressMapper: bool

  AutonatV2Service* = ref object of Service
    config*: AutonatV2ServiceConfig
    confidence: Opt[float]
    newConnectedPeerHandler: PeerEventHandler
    statusAndConfidenceHandler: StatusAndConfidenceHandler
    addressMapper: AddressMapper
    scheduleHandle: Future[void]
    networkReachability*: NetworkReachability
    answers: Deque[NetworkReachability]
    client*: AutonatV2Client
    rng: ref HmacDrbgContext

  StatusAndConfidenceHandler* = proc(
    networkReachability: NetworkReachability, confidence: Opt[float]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

proc new*(
    T: typedesc[AutonatV2ServiceConfig],
    scheduleInterval: Opt[Duration] = Opt.none(Duration),
    askNewConnectedPeers = true,
    numPeersToAsk: int = 5,
    maxQueueSize: int = 10,
    minConfidence: float = 0.3,
    enableAddressMapper = true,
): T =
  return T(
    scheduleInterval: scheduleInterval,
    askNewConnectedPeers: askNewConnectedPeers,
    numPeersToAsk: numPeersToAsk,
    maxQueueSize: maxQueueSize,
    minConfidence: minConfidence,
    enableAddressMapper: enableAddressMapper,
  )

proc new*(
    T: typedesc[AutonatV2Service],
    rng: ref HmacDrbgContext,
    client: AutonatV2Client = AutonatV2Client.new(),
    config: AutonatV2ServiceConfig = AutonatV2ServiceConfig.new(),
): T =
  return T(
    networkReachability: Unknown,
    confidence: Opt.none(float),
    answers: initDeque[NetworkReachability](),
    client: client,
    rng: rng,
    config: config,
  )

proc callHandler(self: AutonatV2Service) {.async: (raises: [CancelledError]).} =
  if not isNil(self.statusAndConfidenceHandler):
    await self.statusAndConfidenceHandler(self.networkReachability, self.confidence)

proc hasEnoughIncomingSlots(switch: Switch): bool =
  # we leave some margin instead of comparing to 0 as a peer could connect to us while we are asking for the dial back
  return switch.connManager.slotsAvailable(In) >= 2

proc doesPeerHaveIncomingConn(switch: Switch, peerId: PeerId): bool =
  return switch.connManager.selectMuxer(peerId, In) != nil

proc handleAnswer(
    self: AutonatV2Service, ans: NetworkReachability
): Future[bool] {.async: (raises: [CancelledError]).} =
  if ans == Unknown:
    return

  let oldNetworkReachability = self.networkReachability
  let oldConfidence = self.confidence

  if self.answers.len == self.config.maxQueueSize:
    self.answers.popFirst()
  self.answers.addLast(ans)

  self.networkReachability = Unknown
  self.confidence = Opt.none(float)
  const reachabilityPriority = [Reachable, NotReachable]
  for reachability in reachabilityPriority:
    let confidence = self.answers.countIt(it == reachability) / self.config.maxQueueSize
    libp2p_autonat_v2_reachability_confidence.set(
      value = confidence, labelValues = [$reachability]
    )
    if self.confidence.isNone and confidence >= self.config.minConfidence:
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
    self: AutonatV2Service, switch: Switch, peerId: PeerId
): Future[NetworkReachability] {.async: (raises: [CancelledError]).} =
  logScope:
    peerId = $peerId

  if doesPeerHaveIncomingConn(switch, peerId):
    return Unknown

  if not hasEnoughIncomingSlots(switch):
    debug "No incoming slots available, not asking peer",
      incomingSlotsAvailable = switch.connManager.slotsAvailable(In)
    return Unknown

  trace "Asking peer for reachability"
  let ans =
    try:
      let reqAddrs = switch.peerInfo.listenAddrs
      let autonatV2Resp = await self.client.sendDialRequest(peerId, reqAddrs)
      debug "AutonatV2Response", autonatV2Resp = autonatV2Resp
      autonatV2Resp.reachability
    except CancelledError as exc:
      raise exc
    except LPStreamError as exc:
      debug "DialRequest stream error", description = exc.msg
      Unknown
    except DialFailedError as exc:
      debug "DialRequest dial failed", description = exc.msg
      Unknown
    except AutonatV2Error as exc:
      debug "DialRequest error", description = exc.msg
      Unknown
  let hasReachabilityOrConfidenceChanged = await self.handleAnswer(ans)
  if hasReachabilityOrConfidenceChanged:
    await self.callHandler()
  await switch.peerInfo.update()
  return ans

proc askConnectedPeers(
    self: AutonatV2Service, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Asking peers for reachability"
  var peers = switch.connectedPeers(Direction.Out)
  self.rng.shuffle(peers)
  var answersFromPeers = 0
  for peer in peers:
    if answersFromPeers >= self.config.numPeersToAsk:
      break
    if not hasEnoughIncomingSlots(switch):
      debug "No incoming slots available, not asking peers",
        incomingSlotsAvailable = switch.connManager.slotsAvailable(In)
      break
    if (await askPeer(self, switch, peer)) != Unknown:
      answersFromPeers.inc()

proc schedule(
    service: AutonatV2Service, switch: Switch, interval: Duration
) {.async: (raises: [CancelledError]).} =
  heartbeat "Scheduling AutonatV2Service run", interval:
    await service.run(switch)

proc addressMapper(
    self: AutonatV2Service, peerStore: PeerStore, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  if not self.networkReachability.isReachable():
    return listenAddrs

  var addrs = newSeq[MultiAddress]()
  for listenAddr in listenAddrs:
    if listenAddr.isPublicMA() or not self.networkReachability.isReachable():
      addrs.add(listenAddr)
    else:
      addrs.add(peerStore.guessDialableAddr(listenAddr))
  return addrs

method setup*(
    self: AutonatV2Service, switch: Switch
): Future[bool] {.async: (raises: [CancelledError]).} =
  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    return await addressMapper(self, switch.peerStore, listenAddrs)

  info "Setting up AutonatV2Service"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if not hasBeenSetup:
    return hasBeenSetup

  if self.config.askNewConnectedPeers:
    self.newConnectedPeerHandler = proc(
        peerId: PeerId, event: PeerEvent
    ): Future[void] {.async: (raises: [CancelledError]).} =
      discard askPeer(self, switch, peerId)

    switch.connManager.addPeerEventHandler(
      self.newConnectedPeerHandler, PeerEventKind.Joined
    )

  self.config.scheduleInterval.withValue(interval):
    self.scheduleHandle = schedule(self, switch, interval)

  if self.config.enableAddressMapper:
    switch.peerInfo.addressMappers.add(self.addressMapper)

  return hasBeenSetup

method run*(
    self: AutonatV2Service, switch: Switch
) {.public, async: (raises: [CancelledError]).} =
  trace "Running AutonatV2Service"
  await askConnectedPeers(self, switch)

method stop*(
    self: AutonatV2Service, switch: Switch
): Future[bool] {.public, async: (raises: [CancelledError]).} =
  info "Stopping AutonatV2Service"
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if not hasBeenStopped:
    return hasBeenStopped
  if not isNil(self.scheduleHandle):
    self.scheduleHandle.cancel()
    self.scheduleHandle = nil
  if not isNil(self.newConnectedPeerHandler):
    switch.connManager.removePeerEventHandler(
      self.newConnectedPeerHandler, PeerEventKind.Joined
    )
  if self.config.enableAddressMapper:
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  await switch.peerInfo.update()
  return hasBeenStopped

proc statusAndConfidenceHandler*(
    self: AutonatV2Service, statusAndConfidenceHandler: StatusAndConfidenceHandler
) =
  self.statusAndConfidenceHandler = statusAndConfidenceHandler
