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

declareGauge(libp2p_gossipsub_peers_per_topic_mesh, "gossipsub peers per topic in mesh", labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_fanout, "gossipsub peers per topic in fanout", labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_gossipsub, "gossipsub peers per topic in gossipsub", labels = ["topic"])

method init*(g: GossipSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await g.handleConn(conn, proto)

  g.handler = handler
  g.codec = GossipSubCodec

proc replenishFanout(g: GossipSub, topic: string) {.async.} =
  ## get fanout peers for a topic
  trace "about to replenish fanout"
  if topic notin g.fanout:
    g.fanout[topic] = initHashSet[string]()

  if g.fanout.getOrDefault(topic).len < GossipSubDLo:
    trace "replenishing fanout", peers = g.fanout.getOrDefault(topic).len
    if topic in g.gossipsub:
      for p in g.gossipsub.getOrDefault(topic):
        if not g.fanout[topic].containsOrIncl(p):
          if g.fanout.getOrDefault(topic).len == GossipSubD:
            break

  libp2p_gossipsub_peers_per_topic_fanout
    .set(g.fanout.getOrDefault(topic).len.int64, labelValues = [topic])
  trace "fanout replenished with peers", peers = g.fanout.getOrDefault(topic).len

proc rebalanceMesh(g: GossipSub, topic: string) {.async.} =
  try:
    trace "about to rebalance mesh"
    # create a mesh topic that we're subscribing to
    if topic notin g.mesh:
      g.mesh[topic] = initHashSet[string]()

    if g.mesh.getOrDefault(topic).len < GossipSubDlo:
      trace "replenishing mesh", topic
      # replenish the mesh if we're below GossipSubDlo
      while g.mesh.getOrDefault(topic).len < GossipSubD:
        trace "gathering peers", peers = g.mesh.getOrDefault(topic).len
        await sleepAsync(1.millis) # don't starve the event loop
        var id: string
        if topic in g.fanout and g.fanout.getOrDefault(topic).len > 0:
          trace "getting peer from fanout", topic,
                                            peers = g.fanout.getOrDefault(topic).len

          id = sample(toSeq(g.fanout.getOrDefault(topic)))
          g.fanout[topic].excl(id)

          if id in g.fanout[topic]:
            continue # we already have this peer in the mesh, try again

          trace "got fanout peer", peer = id
        elif topic in g.gossipsub and g.gossipsub.getOrDefault(topic).len > 0:
          trace "getting peer from gossipsub", topic,
                                               peers = g.gossipsub.getOrDefault(topic).len

          id = sample(toSeq(g.gossipsub[topic]))
          g.gossipsub[topic].excl(id)

          if id in g.mesh[topic]:
            continue # we already have this peer in the mesh, try again

          trace "got gossipsub peer", peer = id
        else:
          trace "no more peers"
          break

        g.mesh[topic].incl(id)
        if id in g.peers:
          let p = g.peers[id]
          # send a graft message to the peer
          await p.sendGraft(@[topic])

    # prune peers if we've gone over
    if g.mesh.getOrDefault(topic).len > GossipSubDhi:
      trace "about to prune mesh", mesh = g.mesh.getOrDefault(topic).len
      while g.mesh.getOrDefault(topic).len > GossipSubD:
        trace "pruning peers", peers = g.mesh[topic].len
        let id = toSeq(g.mesh[topic])[rand(0..<g.mesh[topic].len)]
        g.mesh[topic].excl(id)

        let p = g.peers[id]
        # send a graft message to the peer
        await p.sendPrune(@[topic])

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.getOrDefault(topic).len.int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.getOrDefault(topic).len.int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.getOrDefault(topic).len.int64, labelValues = [topic])

    trace "mesh balanced, got peers", peers = g.mesh.getOrDefault(topic).len,
                                      topicId = topic
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception occurred re-balancing mesh", exc = exc.msg

proc dropFanoutPeers(g: GossipSub) {.async.} =
  # drop peers that we haven't published to in
  # GossipSubFanoutTTL seconds
  var dropping = newSeq[string]()
  for topic, val in g.lastFanoutPubSub:
    if Moment.now > val:
      dropping.add(topic)
      g.fanout.del(topic)

  for topic in dropping:
    g.lastFanoutPubSub.del(topic)

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.getOrDefault(topic).len.int64, labelValues = [topic])

proc getGossipPeers(g: GossipSub): Table[string, ControlMessage] {.gcsafe.} =
  ## gossip iHave messages to peers
  let topics = toHashSet(toSeq(g.mesh.keys)) + toHashSet(toSeq(g.fanout.keys))
  for topic in topics:
    let mesh: HashSet[string] = g.mesh.getOrDefault(topic)
    let fanout: HashSet[string] = g.fanout.getOrDefault(topic)

    let gossipPeers = mesh + fanout
    let mids = g.mcache.window(topic)
    if mids.len > 0:
      let ihave = ControlIHave(topicID: topic,
                               messageIDs: toSeq(mids))

      if topic notin g.gossipsub:
        trace "topic not in gossip array, skipping", topicID = topic
        continue

      while result.len < GossipSubD:
        if g.gossipsub.getOrDefault(topic).len == 0:
          trace "no peers for topic, skipping", topicID = topic
          break

        let id = toSeq(g.gossipsub.getOrDefault(topic)).sample()
        if id in g.gossipsub.getOrDefault(topic):
          g.gossipsub[topic].excl(id)
          if id notin gossipPeers:
            if id notin result:
              result[id] = ControlMessage()
            result[id].ihave.add(ihave)

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.getOrDefault(topic).len.int64, labelValues = [topic])

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat"

      for t in toSeq(g.topics.keys):
        await g.rebalanceMesh(t)

      await g.dropFanoutPeers()
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

    await sleepAsync(1.seconds)

method handleDisconnect*(g: GossipSub, peer: PubSubPeer) {.async.} =
  ## handle peer disconnects
  trace "peer disconnected", peer=peer.id

  await procCall FloodSub(g).handleDisconnect(peer)

  for t in toSeq(g.gossipsub.keys):
    if t in g.gossipsub:
      g.gossipsub[t].excl(peer.id)

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.getOrDefault(t).len.int64, labelValues = [t])

    # mostly for metrics
    await procCall PubSub(g).subscribeTopic(t, false, peer.id)

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

method subscribeToPeer*(p: GossipSub,
                        conn: Connection) {.async.} =
  await procCall PubSub(p).subscribeToPeer(conn)
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

  libp2p_gossipsub_peers_per_topic_gossipsub
    .set(g.gossipsub.getOrDefault(topic).len.int64, labelValues = [topic])

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
          await g.rebalanceMesh(t)                 # gather peers for each topic
          if t in g.floodsub:
            toSendPeers.incl(g.floodsub[t])        # get all floodsub peers for topic

          if t in g.mesh:
            toSendPeers.incl(g.mesh[t])            # get all mesh peers for topic

          if t in g.topics:                        # if we're subscribed to the topic
            for h in g.topics[t].handler:
              trace "calling handler for message", topicId = t,
                                                   localPeer = g.peerInfo.id,
                                                   fromPeer = msg.fromPeer.pretty
              await h(t, msg.data)                 # trigger user provided handler

      # forward the message to all peers interested in it
      for p in toSendPeers:
        if p in g.peers:
          let id = g.peers[p].peerInfo.peerId
          trace "about to forward message to peer", peerId = id, msgs = m.messages

          if id == peer.peerInfo.peerId:
            trace "not forwarding message to originator", peerId = id
            continue

          let msgs = m.messages.filterIt(
            # don't forward to message originator
            id != it.fromPeer
          )

          var sent: seq[Future[void]]
          if msgs.len > 0:
            trace "forwarding message to", peerId = id
            sent.add(g.peers[p].send(@[RPCMsg(messages: msgs)]))
          sent = await allFinished(sent)
          checkFutures(sent)

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
                data: seq[byte]) {.async.} =
  await procCall PubSub(g).publish(topic, data)
  trace "about to publish message on topic", name = topic,
                                             data = data.shortLog

  # TODO: we probably don't need to try multiple times
  if data.len > 0 and topic.len > 0:
    var peers = g.mesh.getOrDefault(topic)
    for _ in 0..<5: # try to get peers up to 5 times
      if peers.len > 0:
        break

      if topic in g.topics: # if we're subscribed to the topic attempt to build a mesh
        await g.rebalanceMesh(topic)
        peers = g.mesh.getOrDefault(topic)
      else: # send to fanout peers
        await g.replenishFanout(topic)
        if topic in g.fanout:
          peers = g.fanout.getOrDefault(topic)
          # set the fanout expiry time
          g.lastFanoutPubSub[topic] = Moment.fromNow(GossipSubFanoutTTL)

      # wait a second between tries
      await sleepAsync(1.seconds)

    let
      msg = Message.init(g.peerInfo, data, topic, g.sign)
      msgId = g.msgIdProvider(msg)

    trace "created new message", msg
    var sent: seq[Future[void]]
    for p in peers:
      if p == g.peerInfo.id:
        continue

      trace "publishing on topic", name = topic
      if msgId notin g.mcache:
        g.mcache.put(msgId, msg)

      if p in g.peers:
        sent.add(g.peers[p].send(@[RPCMsg(messages: @[msg])]))
    checkFutures(await allFinished(sent))

    libp2p_pubsub_messages_published.inc(labelValues = [topic])

method start*(g: GossipSub) {.async.} =
  debug "gossipsub start"

  ## start pubsub
  ## start long running/repeating procedures

  # interlock start to to avoid overlapping to stops
  await g.heartbeatLock.acquire()

  # setup the heartbeat interval
  g.heartbeatRunning = true
  g.heartbeatFut = g.heartbeat()

  g.heartbeatLock.release()

method stop*(g: GossipSub) {.async.} =
  debug "gossipsub stop"

  ## stop pubsub
  ## stop long running tasks

  await g.heartbeatLock.acquire()

  # stop heartbeat interval
  g.heartbeatRunning = false
  if not g.heartbeatFut.finished:
    debug "awaiting last heartbeat"
    await g.heartbeatFut

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
