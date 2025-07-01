# compile time options here
const
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true
  libp2p_pubsub_anonymize {.booldefine.} = false

import hashes, random, tables, sets, sequtils
import chronos, results, stew/byteutils, chronos/ratelimit
import
  ../../libp2p/[
    builders,
    protocols/pubsub/errors,
    protocols/pubsub/pubsub,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/peertable,
    protocols/pubsub/gossipsub,
    protocols/pubsub/floodsub,
    protocols/pubsub/rpc/messages,
    protocols/secure/secure,
  ]
import ../helpers
import chronicles
import metrics

export builders

randomize()

const TEST_GOSSIPSUB_HEARTBEAT_INTERVAL* = 60.milliseconds
const HEARTBEAT_TIMEOUT* = # TEST_GOSSIPSUB_HEARTBEAT_INTERVAL + 20%
  int64(float64(TEST_GOSSIPSUB_HEARTBEAT_INTERVAL.milliseconds) * 1.2).milliseconds

proc waitForHeartbeat*(multiplier: int = 1) {.async.} =
  await sleepAsync(HEARTBEAT_TIMEOUT * multiplier)

proc waitForHeartbeat*(timeout: Duration) {.async.} =
  await sleepAsync(timeout)

proc waitForHeartbeatByEvent*[T: PubSub](node: T, multiplier: int = 1) {.async.} =
  for _ in 0 ..< multiplier:
    let evnt = newAsyncEvent()
    node.heartbeatEvents &= evnt
    await evnt.wait()

type
  TestGossipSub* = ref object of GossipSub
  DValues* = object
    d*: Option[int]
    dLow*: Option[int]
    dHigh*: Option[int]
    dScore*: Option[int]
    dOut*: Option[int]
    dLazy*: Option[int]

proc noop*(data: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  discard

proc voidTopicHandler*(topic: string, data: seq[byte]) {.async.} =
  discard

proc voidPeerHandler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
  discard

proc randomPeerId*(): PeerId =
  try:
    PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
  except CatchableError as exc:
    raise newException(Defect, exc.msg)

proc getPubSubPeer*(p: TestGossipSub, peerId: PeerId): PubSubPeer =
  proc getConn(): Future[Connection] {.
      async: (raises: [CancelledError, GetConnDialError])
  .} =
    try:
      return await p.switch.dial(peerId, GossipSubCodec_12)
    except CancelledError as exc:
      raise exc
    except DialFailedError as e:
      raise (ref GetConnDialError)(parent: e)

  let pubSubPeer = PubSubPeer.new(peerId, getConn, nil, GossipSubCodec_12, 1024 * 1024)
  debug "created new pubsub peer", peerId

  p.peers[peerId] = pubSubPeer

  onNewPeer(p, pubSubPeer)
  pubSubPeer

proc setupGossipSubWithPeers*(
    numPeers: int,
    topics: seq[string],
    populateGossipsub: bool = false,
    populateMesh: bool = false,
    populateFanout: bool = false,
): (TestGossipSub, seq[Connection], seq[PubSubPeer]) =
  let gossipSub = TestGossipSub.init(newStandardSwitch())

  for topic in topics:
    gossipSub.subscribe(topic, voidTopicHandler)
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()

  var conns = newSeq[Connection]()
  var peers = newSeq[PubSubPeer]()
  for i in 0 ..< numPeers:
    let conn = TestBufferStream.new(noop)
    conns &= conn
    let peerId = randomPeerId()
    conn.peerId = peerId
    let peer = gossipSub.getPubSubPeer(peerId)
    peer.sendConn = conn
    peer.handler = voidPeerHandler
    peers &= peer
    for topic in topics:
      if (populateGossipsub):
        gossipSub.gossipsub[topic].incl(peer)
      if (populateMesh):
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)
      if (populateFanout):
        gossipSub.fanout[topic].incl(peer)

  return (gossipSub, conns, peers)

proc setupGossipSubWithPeers*(
    numPeers: int,
    topic: string,
    populateGossipsub: bool = false,
    populateMesh: bool = false,
    populateFanout: bool = false,
): (TestGossipSub, seq[Connection], seq[PubSubPeer]) =
  return setupGossipSubWithPeers(
    numPeers, @[topic], populateGossipsub, populateMesh, populateFanout
  )

proc teardownGossipSub*(gossipSub: TestGossipSub, conns: seq[Connection]) {.async.} =
  await allFuturesThrowing(conns.mapIt(it.close()))

func defaultMsgIdProvider*(m: Message): Result[MessageId, ValidationResult] =
  let mid =
    if m.seqno.len > 0 and m.fromPeer.data.len > 0:
      byteutils.toHex(m.seqno) & $m.fromPeer
    else:
      # This part is irrelevant because it's not standard,
      # We use it exclusively for testing basically and users should
      # implement their own logic in the case they use anonymization
      $m.data.hash & $m.topic.hash
  ok mid.toBytes()

proc applyDValues*(parameters: var GossipSubParams, dValues: Option[DValues]) =
  if dValues.isNone:
    return
  let values = dValues.get
  # Apply each value if it exists
  if values.d.isSome:
    parameters.d = values.d.get
  if values.dLow.isSome:
    parameters.dLow = values.dLow.get
  if values.dHigh.isSome:
    parameters.dHigh = values.dHigh.get
  if values.dScore.isSome:
    parameters.dScore = values.dScore.get
  if values.dOut.isSome:
    parameters.dOut = values.dOut.get
  if values.dLazy.isSome:
    parameters.dLazy = values.dLazy.get

proc generateNodes*(
    num: Natural,
    secureManagers: openArray[SecureProtocol] = [SecureProtocol.Noise],
    msgIdProvider: MsgIdProvider = defaultMsgIdProvider,
    gossip: bool = false,
    triggerSelf: bool = false,
    verifySignature: bool = libp2p_pubsub_verify,
    anonymize: bool = libp2p_pubsub_anonymize,
    sign: bool = libp2p_pubsub_sign,
    sendSignedPeerRecord = false,
    unsubscribeBackoff = 1.seconds,
    pruneBackoff = 1.minutes,
    fanoutTTL = 1.minutes,
    maxMessageSize: int = 1024 * 1024,
    enablePX: bool = false,
    overheadRateLimit: Opt[tuple[bytes: int, interval: Duration]] =
      Opt.none(tuple[bytes: int, interval: Duration]),
    codecs: seq[string] = @[],
    sendIDontWantOnPublish: bool = false,
    heartbeatInterval: Duration = TEST_GOSSIPSUB_HEARTBEAT_INTERVAL,
    floodPublish: bool = false,
    dValues: Option[DValues] = DValues.none(),
    gossipFactor: Option[float] = float.none(),
    opportunisticGraftThreshold: float = 0.0,
    historyLength = 20,
    historyGossip = 5,
    gossipThreshold = -100.0,
    decayInterval = 1.seconds,
    publishThreshold = -1000.0,
    graylistThreshold = -10000.0,
    disconnectBadPeers: bool = false,
): seq[PubSub] =
  for i in 0 ..< num:
    let switch = newStandardSwitch(
      secureManagers = secureManagers, sendSignedPeerRecord = sendSignedPeerRecord
    )
    let pubsub =
      if gossip:
        let g = GossipSub.init(
          switch = switch,
          triggerSelf = triggerSelf,
          verifySignature = verifySignature,
          sign = sign,
          msgIdProvider = msgIdProvider,
          anonymize = anonymize,
          maxMessageSize = maxMessageSize,
          parameters = (
            var p = GossipSubParams.init()
            p.heartbeatInterval = heartbeatInterval
            p.floodPublish = floodPublish
            p.historyLength = historyLength
            p.historyGossip = historyGossip
            p.unsubscribeBackoff = unsubscribeBackoff
            p.pruneBackoff = pruneBackoff
            p.fanoutTTL = fanoutTTL
            p.enablePX = enablePX
            p.overheadRateLimit = overheadRateLimit
            p.sendIDontWantOnPublish = sendIDontWantOnPublish
            p.opportunisticGraftThreshold = opportunisticGraftThreshold
            p.gossipThreshold = gossipThreshold
            p.decayInterval = decayInterval
            p.publishThreshold = publishThreshold
            p.graylistThreshold = graylistThreshold
            p.disconnectBadPeers = disconnectBadPeers
            if gossipFactor.isSome: p.gossipFactor = gossipFactor.get
            applyDValues(p, dValues)
            p
          ),
        )
        if codecs.len != 0:
          g.codecs = codecs
        g.PubSub
      else:
        FloodSub.init(
          switch = switch,
          triggerSelf = triggerSelf,
          verifySignature = verifySignature,
          sign = sign,
          msgIdProvider = msgIdProvider,
          maxMessageSize = maxMessageSize,
          anonymize = anonymize,
        ).PubSub

    switch.mount(pubsub)
    result.add(pubsub)

proc toGossipSub*(nodes: seq[PubSub]): seq[GossipSub] =
  return nodes.mapIt(GossipSub(it))

proc setDefaultTopicParams*(nodes: seq[GossipSub], topic: string): void =
  for node in nodes:
    node.topicParams.mgetOrPut(topic, TopicParams.init()).topicWeight = 1.0

proc getNodeByPeerId*[T: PubSub](nodes: seq[T], peerId: PeerId): GossipSub =
  let filteredNodes = nodes.filterIt(it.peerInfo.peerId == peerId)
  check:
    filteredNodes.len == 1
  return filteredNodes[0]

proc getPeerByPeerId*[T: PubSub](node: T, topic: string, peerId: PeerId): PubSubPeer =
  let filteredPeers =
    node.gossipsub.getOrDefault(topic).toSeq().filterIt(it.peerId == peerId)
  check:
    filteredPeers.len == 1
  return filteredPeers[0]

proc getPeerStats*(node: GossipSub, peerId: PeerId): PeerStats =
  node.peerStats.withValue(peerId, stats):
    return stats[]

proc getPeerScore*(node: GossipSub, peerId: PeerId): float64 =
  return node.getPeerStats(peerId).score

proc getPeerTopicInfo*(node: GossipSub, peerId: PeerId, topic: string): TopicInfo =
  return node.getPeerStats(peerId).topicInfos.getOrDefault(topic)

proc connectNodes*[T: PubSub](dialer: T, target: T) {.async.} =
  doAssert dialer.switch.peerInfo.peerId != target.switch.peerInfo.peerId,
    "Could not connect same peer"
  await dialer.switch.connect(target.peerInfo.peerId, target.peerInfo.addrs)

proc connectNodesStar*[T: PubSub](nodes: seq[T]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.switch.peerInfo.peerId:
        await connectNodes(dialer, node)

proc connectNodesSparse*[T: PubSub](nodes: seq[T], degree: int = 2) {.async.} =
  if nodes.len < degree:
    raise
      (ref CatchableError)(msg: "nodes count needs to be greater or equal to degree!")

  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue

    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.switch.peerInfo.peerId:
        await connectNodes(dialer, node)

proc waitSub*(sender, receiver: auto, key: string) {.async.} =
  if sender == receiver:
    return
  let fsub = GossipSub(sender)
  let peerId = receiver.peerInfo.peerId

  # this is for testing purposes only
  # peers can be inside `mesh` and `fanout`, not just `gossipsub`
  checkUntilTimeout:
    (fsub.gossipsub.hasKey(key) and fsub.gossipsub.hasPeerId(key, peerId)) or
      (fsub.mesh.hasKey(key) and fsub.mesh.hasPeerId(key, peerId)) or
      (fsub.fanout.hasKey(key) and fsub.fanout.hasPeerId(key, peerId))

proc waitSubAllNodes*(nodes: seq[auto], topic: string) {.async.} =
  let numberOfNodes = nodes.len
  for x in 0 ..< numberOfNodes:
    for y in 0 ..< numberOfNodes:
      if x != y:
        await waitSub(nodes[x], nodes[y], topic)

proc waitSubGraph*[T: PubSub](nodes: seq[T], key: string) {.async.} =
  proc isGraphConnected(): bool =
    var
      nodesMesh: Table[PeerId, seq[PeerId]]
      seen: HashSet[PeerId]
    for n in nodes:
      nodesMesh[n.peerInfo.peerId] =
        toSeq(GossipSub(n).mesh.getOrDefault(key).items()).mapIt(it.peerId)
    var ok = 0
    for n in nodes:
      seen.clear()
      proc explore(p: PeerId) =
        if p in seen:
          return
        seen.incl(p)
        for peer in nodesMesh.getOrDefault(p):
          explore(peer)

      explore(n.peerInfo.peerId)
      if seen.len == nodes.len:
        ok.inc()

    return ok == nodes.len

  checkUntilTimeout:
    isGraphConnected()

proc waitForMesh*(
    sender: auto, receiver: auto, key: string, timeoutDuration = 5.seconds
) {.async.} =
  if sender == receiver:
    return

  let
    gossipsubSender = GossipSub(sender)
    receiverPeerId = receiver.peerInfo.peerId

  checkUntilTimeout:
    gossipsubSender.mesh.hasPeerId(key, receiverPeerId)

proc startNodes*[T: PubSub](nodes: seq[T]) {.async.} =
  await allFuturesThrowing(nodes.mapIt(it.switch.start()))

proc stopNodes*[T: PubSub](nodes: seq[T]) {.async.} =
  await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

template startNodesAndDeferStop*[T: PubSub](nodes: seq[T]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

proc subscribeAllNodes*[T: PubSub](
    nodes: seq[T], topic: string, topicHandler: TopicHandler
) =
  for node in nodes:
    node.subscribe(topic, topicHandler)

proc unsubscribeAllNodes*[T: PubSub](
    nodes: seq[T], topic: string, topicHandler: TopicHandler
) =
  for node in nodes:
    node.unsubscribe(topic, topicHandler)

proc subscribeAllNodes*[T: PubSub](
    nodes: seq[T], topic: string, topicHandlers: seq[TopicHandler]
) =
  if nodes.len != topicHandlers.len:
    raise (ref CatchableError)(msg: "nodes and topicHandlers count needs to match!")

  for i in 0 ..< nodes.len:
    nodes[i].subscribe(topic, topicHandlers[i])

template tryPublish*(
    call: untyped, require: int, wait = 10.milliseconds, timeout = 10.seconds
): untyped =
  var
    expiration = Moment.now() + timeout
    pubs = 0
  while pubs < require and Moment.now() < expiration:
    pubs = pubs + call
    await sleepAsync(wait)

  doAssert pubs >= require, "Failed to publish!"

proc createCompleteHandler*(): (
  Future[bool], proc(topic: string, data: seq[byte]) {.async.}
) =
  var fut = newFuture[bool]()
  proc handler(topic: string, data: seq[byte]) {.async.} =
    fut.complete(true)

  return (fut, handler)

proc createCheckForMessages*(): (
  ref seq[Message], proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
) =
  var messages = new seq[Message]
  let checkForMessage = proc(
      peer: PubSubPeer, msgs: var RPCMsg
  ) {.gcsafe, raises: [].} =
    for message in msgs.messages:
      messages[].add(message)

  return (messages, checkForMessage)

proc createCheckForIHave*(): (
  ref seq[ControlIHave], proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
) =
  var messages = new seq[ControlIHave]
  let checkForMessage = proc(
      peer: PubSubPeer, msgs: var RPCMsg
  ) {.gcsafe, raises: [].} =
    if msgs.control.isSome:
      for msg in msgs.control.get.ihave:
        messages[].add(msg)

  return (messages, checkForMessage)

proc createCheckForIWant*(): (
  ref seq[ControlIWant], proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
) =
  var messages = new seq[ControlIWant]
  let checkForMessage = proc(
      peer: PubSubPeer, msgs: var RPCMsg
  ) {.gcsafe, raises: [].} =
    if msgs.control.isSome:
      for msg in msgs.control.get.iwant:
        messages[].add(msg)

  return (messages, checkForMessage)

proc createCheckForIDontWant*(): (
  ref seq[ControlIWant], proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
) =
  var messages = new seq[ControlIWant]
  let checkForMessage = proc(
      peer: PubSubPeer, msgs: var RPCMsg
  ) {.gcsafe, raises: [].} =
    if msgs.control.isSome:
      for msg in msgs.control.get.idontwant:
        messages[].add(msg)

  return (messages, checkForMessage)

proc addOnRecvObserver*[T: PubSub](
    node: T, handler: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
) =
  let pubsubObserver = PubSubObserver(onRecv: handler)
  node.addObserver(pubsubObserver)

proc addIHaveObservers*[T: PubSub](nodes: seq[T]): (ref seq[ref seq[ControlIHave]]) =
  let numberOfNodes = nodes.len
  var allMessages = new seq[ref seq[ControlIHave]]
  allMessages[].setLen(numberOfNodes)

  for i in 0 ..< numberOfNodes:
    var (messages, checkForMessage) = createCheckForIHave()
    nodes[i].addOnRecvObserver(checkForMessage)
    allMessages[i] = messages

  return allMessages

proc addIDontWantObservers*[T: PubSub](
    nodes: seq[T]
): (ref seq[ref seq[ControlIWant]]) =
  let numberOfNodes = nodes.len
  var allMessages = new seq[ref seq[ControlIWant]]
  allMessages[].setLen(numberOfNodes)

  for i in 0 ..< numberOfNodes:
    var (messages, checkForMessage) = createCheckForIDontWant()
    nodes[i].addOnRecvObserver(checkForMessage)
    allMessages[i] = messages

  return allMessages

proc findAndUnsubscribePeers*[T: PubSub](
    nodes: seq[T], peers: seq[PeerId], topic: string, handler: TopicHandler
) =
  for i in 0 ..< nodes.len:
    let node = nodes[i]
    if peers.anyIt(it == node.peerInfo.peerId):
      node.unsubscribe(topic, voidTopicHandler)

proc clearMCache*[T: PubSub](node: T) =
  node.mcache.msgs.clear()
  for i in 0 ..< node.mcache.history.len:
    node.mcache.history[i].setLen(0)
  node.mcache.pos = 0

# TODO: refactor helper methods from testgossipsub.nim
proc setupNodes*(count: int): seq[PubSub] =
  generateNodes(count, gossip = true)

proc connectNodes*(nodes: seq[PubSub], target: PubSub) {.async.} =
  proc handler(topic: string, data: seq[byte]) {.async.} =
    check topic == "foobar"

  for node in nodes:
    node.subscribe("foobar", handler)
    await node.switch.connect(target.peerInfo.peerId, target.peerInfo.addrs)

proc baseTestProcedure*(
    nodes: seq[PubSub],
    gossip1: GossipSub,
    numPeersFirstMsg: int,
    numPeersSecondMsg: int,
) {.async.} =
  proc handler(topic: string, data: seq[byte]) {.async.} =
    check topic == "foobar"

  block setup:
    for i in 0 ..< 50:
      if (await nodes[0].publish("foobar", ("Hello!" & $i).toBytes())) == 19:
        break setup
      await sleepAsync(10.milliseconds)
    check false

  check (await nodes[0].publish("foobar", newSeq[byte](2_500_000))) == numPeersFirstMsg
  check (await nodes[0].publish("foobar", newSeq[byte](500_001))) == numPeersSecondMsg

  # Now try with a mesh
  gossip1.subscribe("foobar", handler)
  checkUntilTimeout:
    gossip1.mesh.peers("foobar") > 5

  # use a different length so that the message is not equal to the last
  check (await nodes[0].publish("foobar", newSeq[byte](500_000))) == numPeersSecondMsg

proc `$`*(peer: PubSubPeer): string =
  shortLog(peer)

proc currentRateLimitHits*(label: string = "nim-libp2p"): float64 =
  try:
    libp2p_gossipsub_peers_rate_limit_hits.valueByName(
      "libp2p_gossipsub_peers_rate_limit_hits_total", @[label]
    )
  except KeyError:
    0

proc addDirectPeer*[T: PubSub](node: T, target: T) {.async.} =
  doAssert node.switch.peerInfo.peerId != target.switch.peerInfo.peerId,
    "Could not add same peer"
  await node.addDirectPeer(target.switch.peerInfo.peerId, target.switch.peerInfo.addrs)

proc addDirectPeerStar*[T: PubSub](nodes: seq[T]) {.async.} =
  for node in nodes:
    for target in nodes:
      if node.switch.peerInfo.peerId != target.switch.peerInfo.peerId:
        await addDirectPeer(node, target)
