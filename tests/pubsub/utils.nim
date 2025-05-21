# compile time options here
const
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true
  libp2p_pubsub_anonymize {.booldefine.} = false

import hashes, random, tables, sets, sequtils, sugar
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

export builders

randomize()

const TEST_GOSSIPSUB_HEARTBEAT_INTERVAL* = 60.milliseconds
const HEARTBEAT_TIMEOUT* = # TEST_GOSSIPSUB_HEARTBEAT_INTERVAL + 20%
  int64(float64(TEST_GOSSIPSUB_HEARTBEAT_INTERVAL.milliseconds) * 1.2).milliseconds

proc waitForHeartbeat*(multiplier: int = 1) {.async.} =
  await sleepAsync(HEARTBEAT_TIMEOUT * multiplier)

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
  await gossipSub.switch.stop()

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
    gossipSubVersion: string = "",
    sendIDontWantOnPublish: bool = false,
    heartbeatInterval: Duration = TEST_GOSSIPSUB_HEARTBEAT_INTERVAL,
    floodPublish: bool = false,
    dValues: Option[DValues] = DValues.none(),
    gossipFactor: Option[float] = float.none(),
    opportunisticGraftThreshold: float = 0.0,
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
            p.historyLength = 20
            p.historyGossip = 20
            p.unsubscribeBackoff = unsubscribeBackoff
            p.pruneBackoff = pruneBackoff
            p.fanoutTTL = fanoutTTL
            p.enablePX = enablePX
            p.overheadRateLimit = overheadRateLimit
            p.sendIDontWantOnPublish = sendIDontWantOnPublish
            p.opportunisticGraftThreshold = opportunisticGraftThreshold
            if gossipFactor.isSome: p.gossipFactor = gossipFactor.get
            applyDValues(p, dValues)
            p
          ),
        )
        # set some testing params, to enable scores
        g.topicParams.mgetOrPut("foobar", TopicParams.init()).topicWeight = 1.0
        g.topicParams.mgetOrPut("foo", TopicParams.init()).topicWeight = 1.0
        g.topicParams.mgetOrPut("bar", TopicParams.init()).topicWeight = 1.0
        if gossipSubVersion != "":
          g.codecs = @[gossipSubVersion]
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

proc activeWait(
    interval: Duration, maximum: Moment, timeoutErrorMessage = "Timeout on activeWait"
) {.async.} =
  await sleepAsync(interval)
  if Moment.now() >= maximum:
    raise (ref CatchableError)(msg: timeoutErrorMessage)

proc waitSub*(sender, receiver: auto, key: string) {.async.} =
  if sender == receiver:
    return
  let timeout = Moment.now() + 5.seconds
  let fsub = GossipSub(sender)

  # this is for testing purposes only
  # peers can be inside `mesh` and `fanout`, not just `gossipsub`
  while (
    not fsub.gossipsub.hasKey(key) or
    not fsub.gossipsub.hasPeerId(key, receiver.peerInfo.peerId)
  ) and
      (
        not fsub.mesh.hasKey(key) or
        not fsub.mesh.hasPeerId(key, receiver.peerInfo.peerId)
      ) and (
    not fsub.fanout.hasKey(key) or
    not fsub.fanout.hasPeerId(key, receiver.peerInfo.peerId)
  )
  :
    trace "waitSub sleeping..."
    await activeWait(5.milliseconds, timeout, "waitSub timeout!")

proc waitSubAllNodes*(nodes: seq[auto], topic: string) {.async.} =
  let numberOfNodes = nodes.len
  for x in 0 ..< numberOfNodes:
    for y in 0 ..< numberOfNodes:
      if x != y:
        await waitSub(nodes[x], nodes[y], topic)

proc waitSubGraph*[T: PubSub](nodes: seq[T], key: string) {.async.} =
  let timeout = Moment.now() + 5.seconds
  while true:
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
    if ok == nodes.len:
      return
    trace "waitSubGraph sleeping..."
    await activeWait(5.milliseconds, timeout, "waitSubGraph timeout!")

proc waitForMesh*(
    sender: auto, receiver: auto, key: string, timeoutDuration = 5.seconds
) {.async.} =
  if sender == receiver:
    return

  let
    timeoutMoment = Moment.now() + timeoutDuration
    gossipsubSender = GossipSub(sender)
    receiverPeerId = receiver.peerInfo.peerId

  while not gossipsubSender.mesh.hasPeerId(key, receiverPeerId):
    trace "waitForMesh sleeping..."
    await activeWait(5.milliseconds, timeoutMoment, "waitForMesh timeout!")

type PeerTableType* {.pure.} = enum
  Gossipsub = "gossipsub"
  Mesh = "mesh"
  Fanout = "fanout"

proc waitForPeersInTable*(
    nodes: seq[auto],
    topic: string,
    peerCounts: seq[int],
    table: PeerTableType,
    timeout = 1.seconds,
) {.async.} =
  ## Wait until each node in `nodes` has at least the corresponding number of peers from `peerCounts`
  ## in the specified table (mesh, gossipsub, or fanout) for the given topic

  doAssert nodes.len == peerCounts.len, "Node count must match peer count expectations"

  # Helper proc to check current state and update satisfaction status
  proc checkState(
      nodes: seq[auto],
      topic: string,
      peerCounts: seq[int],
      table: PeerTableType,
      satisfied: var seq[bool],
  ): bool =
    for i in 0 ..< nodes.len:
      if not satisfied[i]:
        let fsub = GossipSub(nodes[i])
        let currentCount =
          case table
          of PeerTableType.Mesh:
            fsub.mesh.getOrDefault(topic).len
          of PeerTableType.Gossipsub:
            fsub.gossipsub.getOrDefault(topic).len
          of PeerTableType.Fanout:
            fsub.fanout.getOrDefault(topic).len
        satisfied[i] = currentCount >= peerCounts[i]
    return satisfied.allIt(it)

  let timeoutMoment = Moment.now() + timeout
  var
    satisfied = newSeq[bool](nodes.len)
    allSatisfied = false

  allSatisfied = checkState(nodes, topic, peerCounts, table, satisfied) # Initial check
  # Continue checking until all requirements are met or timeout
  while not allSatisfied:
    await activeWait(
      5.milliseconds,
      timeoutMoment,
      "Timeout waiting for peer counts in " & $table & " for topic " & topic,
    )
    allSatisfied = checkState(nodes, topic, peerCounts, table, satisfied)

proc waitForPeersInTable*(
    node: auto, topic: string, peerCount: int, table: PeerTableType, timeout = 1.seconds
) {.async.} =
  await waitForPeersInTable(@[node], topic, @[peerCount], table, timeout)

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

proc findAndStopPeers*[T: PubSub](
    nodes: seq[T], peers: seq[PeerId], topic: string, handler: TopicHandler
) {.async.} =
  for i in 0 ..< nodes.len:
    let node = nodes[i]
    if peers.any(
      proc(p: PeerId): bool =
        p == node.peerInfo.peerId
    ):
      node.unsubscribe(topic, voidTopicHandler)
      await node.stop()

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
