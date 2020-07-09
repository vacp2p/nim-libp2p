## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sets, options, sequtils, random
import chronos, chronicles, metrics
import pubsub,
       floodsub,
       pubsubpeer,
       mcache,
       timedcache,
       rpc/[messages, message],
       ../protocol,
       ../../peerinfo,
       ../../stream/connection,
       ../../peerid,
       ../../errors,
       ../../utility

logScope:
  topics = "gossipsub"

const GossipSubCodec* = "/meshsub/1.0.0"

# overlay parameters
const GossipSubD* = 6
const GossipSubDlo* = 4
const GossipSubDhi* = 12

# gossip parameters
const GossipSubHistoryLength* = 5
const GossipSubHistoryGossip* = 3

# heartbeat interval
const GossipSubHeartbeatInitialDelay* = 100.millis
const GossipSubHeartbeatInterval* = 1.seconds

# fanout ttl
const GossipSubFanoutTTL* = 1.minutes

type
  GossipSub* = ref object of FloodSub
    mesh*: Table[string, HashSet[string]]      # meshes - topic to peer
    fanout*: Table[string, HashSet[string]]    # fanout - topic to peer
    gossipsub*: Table[string, HashSet[string]] # topic to peer map of all gossipsub peers
    lastFanoutPubSub*: Table[string, Moment]   # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]  # pending gossip
    control*: Table[string, ControlMessage]    # pending control messages
    mcache*: MCache                            # messages cache
    heartbeatFut: Future[void]                 # cancellation future for heartbeat interval
    heartbeatRunning: bool
    heartbeatLock: AsyncLock                   # heartbeat lock to prevent two consecutive concurrent heartbeats

declareGauge(libp2p_gossipsub_peers_per_topic_mesh,
  "gossipsub peers per topic in mesh",
  labels = ["topic"])

declareGauge(libp2p_gossipsub_peers_per_topic_fanout,
  "gossipsub peers per topic in fanout",
  labels = ["topic"])

declareGauge(libp2p_gossipsub_peers_per_topic_gossipsub,
  "gossipsub peers per topic in gossipsub",
  labels = ["topic"])

method init*(g: GossipSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await g.handleConn(conn, proto)

  g.handler = handler
  g.codec = GossipSubCodec

proc replenishFanout(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  trace "about to replenish fanout"
  if topic notin g.fanout:
    g.fanout[topic] = initHashSet[string]()

  if g.fanout.getOrDefault(topic).len < GossipSubDLo:
    trace "replenishing fanout", peers = g.fanout.getOrDefault(topic).len
    if topic in toSeq(g.gossipsub.keys):
      for p in g.gossipsub.getOrDefault(topic):
        if not g.fanout[topic].containsOrIncl(p):
          if g.fanout.getOrDefault(topic).len == GossipSubD:
            break

  libp2p_gossipsub_peers_per_topic_fanout
    .set(g.fanout.getOrDefault(topic).len.int64,
      labelValues = [topic])

  trace "fanout replenished with peers", peers = g.fanout.getOrDefault(topic).len

template moveToMeshHelper(g: GossipSub,
                          topic: string,
                          table: Table[string, HashSet[string]]) =
  ## move peers from `table` into `mesh`
  ##
  var peerIds = toSeq(table.getOrDefault(topic))

  logScope:
    topic = topic
    meshPeers = g.mesh.getOrDefault(topic).len
    peers = peerIds.len

  shuffle(peerIds)
  for id in peerIds:
    if g.mesh.getOrDefault(topic).len > GossipSubD:
      break

    trace "gathering peers for mesh"
    if topic notin table:
      continue

    trace "getting peers", topic,
                           peers = peerIds.len

    table[topic].excl(id) # always exclude
    if id in g.mesh[topic]:
      continue # we already have this peer in the mesh, try again

    if id in g.peers:
      let p = g.peers[id]
      if p.connected:
        # send a graft message to the peer
        await p.sendGraft(@[topic])
        g.mesh[topic].incl(id)
        trace "got peer", peer = id

proc rebalanceMesh(g: GossipSub, topic: string) {.async.} =
  try:
    trace "about to rebalance mesh"
    # create a mesh topic that we're subscribing to
    if topic notin g.mesh:
      g.mesh[topic] = initHashSet[string]()

    if g.mesh.getOrDefault(topic).len < GossipSubDlo:
      trace "replenishing mesh", topic
      # replenish the mesh if we're below GossipSubDlo

      # move fanout nodes first
      g.moveToMeshHelper(topic, g.fanout)

      # move gossipsub nodes second
      g.moveToMeshHelper(topic, g.gossipsub)

    if g.mesh.getOrDefault(topic).len > GossipSubDhi:
      # prune peers if we've gone over
      var mesh = toSeq(g.mesh.getOrDefault(topic))
      shuffle(mesh)

      trace "about to prune mesh", mesh = mesh.len
      for id in mesh:
        if g.mesh.getOrDefault(topic).len <= GossipSubD:
          break

        trace "pruning peers", peers = g.mesh[topic].len
        let p = g.peers[id]
        # send a graft message to the peer
        await p.sendPrune(@[topic])
        g.mesh[topic].excl(id)
        if topic in g.gossipsub:
          g.gossipsub[topic].incl(id)

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.getOrDefault(topic).len.int64,
        labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.getOrDefault(topic).len.int64,
        labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.getOrDefault(topic).len.int64,
        labelValues = [topic])

    trace "mesh balanced, got peers", peers = g.mesh.getOrDefault(topic).len,
                                      topicId = topic
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "exception occurred re-balancing mesh", exc = exc.msg

proc dropFanoutPeers(g: GossipSub) {.async.} =
  # drop peers that we haven't published to in
  # GossipSubFanoutTTL seconds
  var dropping = newSeq[string]()
  for topic, val in g.lastFanoutPubSub:
    if Moment.now > val:
      dropping.add(topic)
      g.fanout.del(topic)
      trace "dropping fanout topic", topic

  for topic in dropping:
    g.lastFanoutPubSub.del(topic)

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.getOrDefault(topic).len.int64, labelValues = [topic])

proc getGossipPeers(g: GossipSub): Table[string, ControlMessage] {.gcsafe.} =
  ## gossip iHave messages to peers
  ##

  trace "getting gossip peers (iHave)"
  let topics = toHashSet(toSeq(g.mesh.keys)) + toHashSet(toSeq(g.fanout.keys))
  let controlMsg = ControlMessage()
  for topic in topics:
    var allPeers = toSeq(g.gossipsub.getOrDefault(topic))
    shuffle(allPeers)

    let mesh = g.mesh.getOrDefault(topic)
    let fanout = g.fanout.getOrDefault(topic)

    let gossipPeers = mesh + fanout
    let mids = g.mcache.window(topic)
    if mids.len <= 0:
      continue

    let ihave = ControlIHave(topicID: topic,
                              messageIDs: toSeq(mids))

    if topic notin g.gossipsub:
      trace "topic not in gossip array, skipping", topicID = topic
      continue

    for id in allPeers:
      if result.len >= GossipSubD:
        trace "got gossip peers", peers = result.len
        break

      if allPeers.len == 0:
        trace "no peers for topic, skipping", topicID = topic
        break

      if id in gossipPeers:
        continue

      if id notin result:
        result[id] = controlMsg

      result[id].ihave.add(ihave)

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat"

      for t in toSeq(g.topics.keys):
        await g.rebalanceMesh(t)

      await g.dropFanoutPeers()

      # replenish known topics to the fanout
      for t in toSeq(g.fanout.keys):
        g.replenishFanout(t)

      let peers = g.getGossipPeers()
      var sent: seq[Future[void]]
      for peer in peers.keys:
        if peer in g.peers:
          sent &= g.peers[peer].send(@[RPCMsg(control: some(peers[peer]))])
      checkFutures(await allFinished(sent))

      g.mcache.shift() # shift the cache
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception ocurred in gossipsub heartbeat", exc = exc.msg

    await sleepAsync(5.seconds)

method handleDisconnect*(g: GossipSub, peer: PubSubPeer) =
  ## handle peer disconnects
  procCall FloodSub(g).handleDisconnect(peer)

  for t in toSeq(g.gossipsub.keys):
    if t in g.gossipsub:
      g.gossipsub[t].excl(peer.id)

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.getOrDefault(t).len.int64, labelValues = [t])

  for t in toSeq(g.mesh.keys):
    if t in g.mesh:
      g.mesh[t].excl(peer.id)

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh[t].len.int64, labelValues = [t])

  for t in toSeq(g.fanout.keys):
    if t in g.fanout:
      g.fanout[t].excl(peer.id)

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout[t].len.int64, labelValues = [t])

method subscribePeer*(p: GossipSub,
                        conn: Connection) =
  procCall PubSub(p).subscribePeer(conn)
  asyncCheck p.handleConn(conn, GossipSubCodec)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe, async.} =
  await procCall PubSub(g).subscribeTopic(topic, subscribe, peerId)

  if topic notin g.gossipsub:
    g.gossipsub[topic] = initHashSet[string]()

  if subscribe:
    trace "adding subscription for topic", peer = peerId, name = topic
    # subscribe remote peer to the topic
    g.gossipsub[topic].incl(peerId)
  else:
    trace "removing subscription for topic", peer = peerId, name = topic
    # unsubscribe remote peer from the topic
    g.gossipsub[topic].excl(peerId)
    if peerId in g.mesh.getOrDefault(topic):
      g.mesh[topic].excl(peerId)
    if peerId in g.fanout.getOrDefault(topic):
      g.fanout[topic].excl(peerId)

  libp2p_gossipsub_peers_per_topic_gossipsub
    .set(g.gossipsub[topic].len.int64, labelValues = [topic])

  trace "gossip peers", peers = g.gossipsub[topic].len, topic

  # also rebalance current topic if we are subbed to
  if topic in g.topics:
    await g.rebalanceMesh(topic)

proc handleGraft(g: GossipSub,
                 peer: PubSubPeer,
                 grafts: seq[ControlGraft],
                 respControl: var ControlMessage) =
  for graft in grafts:
    trace "processing graft message", peer = peer.id,
                                      topicID = graft.topicID

    if graft.topicID in g.topics:
      if g.mesh.len < GossipSubD:
        g.mesh[graft.topicID].incl(peer.id)
      else:
        g.gossipsub[graft.topicID].incl(peer.id)
    else:
      respControl.prune.add(ControlPrune(topicID: graft.topicID))

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh[graft.topicID].len.int64, labelValues = [graft.topicID])

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub[graft.topicID].len.int64, labelValues = [graft.topicID])

proc handlePrune(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    trace "processing prune message", peer = peer.id,
                                      topicID = prune.topicID

    if prune.topicID in g.mesh:
      g.mesh[prune.topicID].excl(peer.id)
      g.gossipsub[prune.topicID].incl(peer.id)
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh[prune.topicID].len.int64, labelValues = [prune.topicID])

proc handleIHave(g: GossipSub,
                 peer: PubSubPeer,
                 ihaves: seq[ControlIHave]): ControlIWant =
  for ihave in ihaves:
    trace "processing ihave message", peer = peer.id,
                                      topicID = ihave.topicID,
                                      msgs = ihave.messageIDs

    if ihave.topicID in g.mesh:
      for m in ihave.messageIDs:
        if m notin g.seen:
          result.messageIDs.add(m)

proc handleIWant(g: GossipSub,
                 peer: PubSubPeer,
                 iwants: seq[ControlIWant]): seq[Message] =
  for iwant in iwants:
    for mid in iwant.messageIDs:
      trace "processing iwant message", peer = peer.id,
                                        messageID = mid
      let msg = g.mcache.get(mid)
      if msg.isSome:
        result.add(msg.get())

method rpcHandler*(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsgs: seq[RPCMsg]) {.async.} =
  await procCall PubSub(g).rpcHandler(peer, rpcMsgs)

  for m in rpcMsgs:                                  # for all RPC messages
    if m.messages.len > 0:                           # if there are any messages
      var toSendPeers: HashSet[string]
      for msg in m.messages:                         # for every message
        let msgId = g.msgIdProvider(msg)
        logScope: msgId

        if msgId in g.seen:
          trace "message already processed, skipping"
          continue

        trace "processing message"

        g.seen.put(msgId)                        # add the message to the seen cache

        if g.verifySignature and not msg.verify(peer.peerInfo):
          trace "dropping message due to failed signature verification"
          continue

        if not (await g.validate(msg)):
          trace "dropping message due to failed validation"
          continue

        # this shouldn't happen
        if g.peerInfo.peerId == msg.fromPeer:
          trace "skipping messages from self"
          continue

        for t in msg.topicIDs:                     # for every topic in the message
          if t in g.floodsub:
            toSendPeers.incl(g.floodsub[t])        # get all floodsub peers for topic

          if t in g.mesh:
            toSendPeers.incl(g.mesh[t])            # get all mesh peers for topic

          if t in g.topics:                        # if we're subscribed to the topic
            for h in g.topics[t].handler:
              trace "calling handler for message", topicId = t,
                                                   localPeer = g.peerInfo.id,
                                                   fromPeer = msg.fromPeer.pretty
              try:
                await h(t, msg.data)                 # trigger user provided handler
              except CatchableError as exc:
                trace "exception in message handler", exc = exc.msg

      # forward the message to all peers interested in it
      let (published, failed) = await g.sendHelper(toSendPeers, m.messages)
      for p in failed:
        let peer = g.peers.getOrDefault(p)
        if not(isNil(peer)):
          g.handleDisconnect(peer) # cleanup failed peers

      trace "forwared message to peers", peers = published.len

    var respControl: ControlMessage
    if m.control.isSome:
      var control: ControlMessage = m.control.get()
      let iWant: ControlIWant = g.handleIHave(peer, control.ihave)
      if iWant.messageIDs.len > 0:
        respControl.iwant.add(iWant)
      let messages: seq[Message] = g.handleIWant(peer, control.iwant)

      g.handleGraft(peer, control.graft, respControl)
      g.handlePrune(peer, control.prune)

      if respControl.graft.len > 0 or respControl.prune.len > 0 or
         respControl.ihave.len > 0 or respControl.iwant.len > 0:
        await peer.send(@[RPCMsg(control: some(respControl), messages: messages)])

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  await procCall PubSub(g).subscribe(topic, handler)
  await g.rebalanceMesh(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) {.async.} =
  await procCall PubSub(g).unsubscribe(topics)

  for pair in topics:
    let topic = pair.topic
    if topic in g.mesh:
      let peers = g.mesh.getOrDefault(topic)
      g.mesh.del(topic)
      for id in peers:
        let p = g.peers[id]
        await p.sendPrune(@[topic])

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data)
  trace "about to publish message on topic", name = topic,
                                             data = data.shortLog
  var peers: HashSet[string]
  if topic.len <= 0: # data could be 0/empty
    return 0

  if topic in g.topics: # if we're subscribed use the mesh
    peers = g.mesh.getOrDefault(topic)
  else: # not subscribed, send to fanout peers
    # try optimistically
    peers = g.fanout.getOrDefault(topic)
    if peers.len == 0:
      # ok we had nothing.. let's try replenish inline
      g.replenishFanout(topic)
      peers = g.fanout.getOrDefault(topic)

  let
    msg = Message.init(g.peerInfo, data, topic, g.sign)
    msgId = g.msgIdProvider(msg)

  trace "created new message", msg

  trace "publishing on topic", name = topic, peers = peers
  if msgId notin g.mcache:
    g.mcache.put(msgId, msg)

  let (published, failed) = await g.sendHelper(peers, @[msg])
  for p in failed:
    let peer = g.peers.getOrDefault(p)
    g.handleDisconnect(peer) # cleanup failed peers

  if published.len > 0:
    libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "published message to peers", peers = published.len,
                                      msg = msg.shortLog()
  return published.len

method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  ## start pubsub
  ## start long running/repeating procedures

  # interlock start to to avoid overlapping to stops
  await g.heartbeatLock.acquire()

  # setup the heartbeat interval
  g.heartbeatRunning = true
  g.heartbeatFut = g.heartbeat()

  g.heartbeatLock.release()

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"

  ## stop pubsub
  ## stop long running tasks

  await g.heartbeatLock.acquire()

  # stop heartbeat interval
  g.heartbeatRunning = false
  if not g.heartbeatFut.finished:
    trace "awaiting last heartbeat"
    await g.heartbeatFut
    trace "heartbeat stopped"

  g.heartbeatLock.release()

method initPubSub*(g: GossipSub) =
  procCall FloodSub(g).initPubSub()

  randomize()
  g.mcache = newMCache(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[string]]()     # meshes - topic to peer
  g.fanout = initTable[string, HashSet[string]]()   # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[string]]()# topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Moment]()  # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]()   # pending control messages
  g.heartbeatLock = newAsyncLock()
