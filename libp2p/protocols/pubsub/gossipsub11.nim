## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sets, options, sequtils, random, algorithm
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

const
  GossipSubCodec* = "/meshsub/1.0.0"
  GossipSubCodec_11* = "/meshsub/1.1.0"

# overlay parameters
const
  GossipSubD* = 6
  GossipSubDlo* = 4
  GossipSubDhi* = 12

# gossip parameters
const
  GossipSubHistoryLength* = 5
  GossipSubHistoryGossip* = 3
  GossipBackoffPeriod* = 1.minutes

# heartbeat interval
const
  GossipSubHeartbeatInitialDelay* = 100.millis
  GossipSubHeartbeatInterval* = 1.seconds

# fanout ttl
const 
  GossipSubFanoutTTL* = 1.minutes

type
  GossipSubParams* = object
    pruneBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float
    dScore*: int
    dOut*: int

    publishThreshold*: float

  GossipSub* = ref object of FloodSub
    parameters*: GossipSubParams
    mesh*: Table[string, HashSet[string]]      # meshes - topic to peer
    fanout*: Table[string, HashSet[string]]    # fanout - topic to peer
    gossipsub*: Table[string, HashSet[string]] # topic to peer map of all gossipsub peers
    explicit*: Table[string, HashSet[string]] # # topic to peer map of all explicit peers
    explicitPeers*: HashSet[string] # explicit (always connected/forward) peers
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

proc init*(_: type[GossipSubParams]): GossipSubParams =
  GossipSubParams(
      pruneBackoff: 1.minutes,
      floodPublish: true,
      gossipFactor: 0.25,
      dScore: 4,
      dOut: 2,
      publishThreshold: 1.0,
    )

method init*(g: GossipSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    if conn.peerInfo.maintain:
      g.explicitPeers.incl(conn.peerInfo.id)

    await g.handleConn(conn, proto)

  g.handler = handler
  g.codecs &= GossipSubCodec_11
  g.codecs &= GossipSubCodec

proc replenishFanout(g: GossipSub, topic: string) =
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

    # https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.0.md#mesh-maintenance
    if g.mesh.getOrDefault(topic).len < GossipSubDlo  and topic in g.topics:
      var availPeers = toSeq(g.gossipsub.getOrDefault(topic))
      shuffle(availPeers)
      if availPeers.len > GossipSubD:
        availPeers = availPeers[0..<GossipSubD]

      trace "gathering more mesh peers", current = g.mesh.getOrDefault(topic).len, avail = availPeers.len

      for id in availPeers:
        if id in g.mesh[topic]:
          continue # we already have this peer in the mesh, try again

        trace "got gossipsub peer", peer = id

        g.mesh[topic].incl(id)
        if id in g.peers:
          let p = g.peers[id]
          # send a graft message to the peer
          await p.sendGraft(@[topic])
    
    # prune peers if we've gone over
    if g.mesh.getOrDefault(topic).len > GossipSubDhi:
      trace "about to prune mesh", mesh = g.mesh.getOrDefault(topic).len
      
      # ATTN possible perf bottleneck here... score is a "red" function
      # and we call a lot of Table[] etc etc

      # gather peers
      var peers = toSeq(g.mesh[topic])
      # sort peers by score
      peers.sort(proc (x, y: string): int =
        let
          peerx = g.peers[x].score()
          peery = g.peers[y].score()
        if peerx < peery: -1
        elif peerx == peery: 0
        else: 1)
      
      while g.mesh.getOrDefault(topic).len > GossipSubD:
        trace "pruning peers", peers = g.mesh[topic].len

        # pop a low score peer
        let
          id = peers.pop()
        g.mesh[topic].excl(id)

        # send a prune message to the peer
        let
          p = g.peers[id]
        # TODO send a set of other peers where the pruned peer can connect to reform its mesh
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
      
      var extraPeers = toSeq(g.gossipsub[topic])
      shuffle(extraPeers)
      for peer in extraPeers:
          if  result.len < GossipSubD and 
              peer notin gossipPeers and 
              peer notin result:
            result[peer] = ControlMessage(ihave: @[ihave])

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    withLock g.heartbeatLock:
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

    await sleepAsync(1.seconds)

method handleDisconnect*(g: GossipSub, peer: PubSubPeer) {.async.} =
  ## handle peer disconnects
  trace "peer disconnected", peer=peer.id

  await procCall FloodSub(g).handleDisconnect(peer)

  withLock g.heartbeatLock:
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
  asyncCheck p.handleConn(conn, GossipSubCodec_11)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe, async.} =
  await procCall PubSub(g).subscribeTopic(topic, subscribe, peerId)

  withLock g.heartbeatLock:
    if topic notin g.gossipsub:
      g.gossipsub[topic] = initHashSet[string]()

    if subscribe:
      trace "adding subscription for topic", peer = peerId, name = topic
      # subscribe remote peer to the topic
      g.gossipsub[topic].incl(peerId)
      if peerId in g.explicit:
        g.explicit[topic].incl(peerId)
    else:
      trace "removing subscription for topic", peer = peerId, name = topic
      # unsubscribe remote peer from the topic
      g.gossipsub[topic].excl(peerId)
      if peerId in g.explicit:
        g.explicit[topic].excl(peerId)

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

    # It is an error to GRAFT on a explicit peer
    if peer.peerInfo.maintain:
      trace "attempt to graft an explicit peer",  peer=peer.id, 
                                                  topicID=graft.topicID
      # and such an attempt should be logged and rejected with a PRUNE
      respControl.prune.add(ControlPrune(topicID: graft.topicID))
      continue

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
          if t in g.floodsub:
            toSendPeers.incl(g.floodsub[t])        # get all floodsub peers for topic

          if t in g.mesh:
            toSendPeers.incl(g.mesh[t])            # get all mesh peers for topic

          if t in g.explicit:
            toSendPeers.incl(g.explicit[t])        # always forward to explicit peers

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
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data)
  trace "about to publish message on topic", name = topic,
                                             data = data.shortLog
  # directly copy explicit peers
  # as we will always publish to those
  var peers = g.explicitPeers

  if topic.len > 0: # data could be 0/empty
    if g.parameters.floodPublish:
      for id, peer in g.peers:
        if  topic in peer.topics and
            peer.score() >= g.parameters.publishThreshold:
          debug "publish: including flood/high score peer", peer = id
          peers.incl(id)

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

    var sent: seq[Future[void]]
    for p in peers:
      # avoid sending to self
      if p == g.peerInfo.id:
        continue

      let peer = g.peers.getOrDefault(p)
      if not isNil(peer) and not isNil(peer.peerInfo):
        trace "publish: sending message to peer", peer = p
        sent.add(peer.send(@[RPCMsg(messages: @[msg])]))
      else:
        # this absolutely should not happen
        # if it happens there is a bug that needs fixing asap
        # this ain't no place to manage connections
        fatal "publish: peer or peerInfo was nil", missing = p
        doAssert(false, "publish: peer or peerInfo was nil")
    
    sent = await allFinished(sent)
    checkFutures(sent)

    libp2p_pubsub_messages_published.inc(labelValues = [topic])

    return sent.filterIt(not it.failed).len
  else:
    return 0

  
method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  ## start pubsub
  ## start long running/repeating procedures

  withLock g.heartbeatLock:
    # setup the heartbeat interval
    g.heartbeatRunning = true
    g.heartbeatFut = g.heartbeat()

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"

  ## stop pubsub
  ## stop long running tasks

  withLock g.heartbeatLock:
    # stop heartbeat interval
    g.heartbeatRunning = false
    if not g.heartbeatFut.finished:
      trace "awaiting last heartbeat"
      await g.heartbeatFut

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
