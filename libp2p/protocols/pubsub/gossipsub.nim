## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sets, options, sequtils, random, algorithm]
import chronos, chronicles, metrics
import pubsub,
       floodsub,
       pubsubpeer,
       peertable,
       mcache,
       timedcache,
       rpc/[messages, message],
       ../protocol,
       ../../peerinfo,
       ../../stream/connection,
       ../../peerid,
       ../../errors,
       ../../utility
import stew/results
export results

logScope:
  topics = "gossipsub"

const
  GossipSubCodec* = "/meshsub/1.1.0"
  GossipSubCodec_10* = "/meshsub/1.0.0"

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

    gossipThreshold*: float
    publishThreshold*: float
    graylistThreshold*: float
    acceptPXThreshold*: float
    opportunisticGraftThreshold*: float
    decayInterval*: Duration
    decayToZero*: float
    retainScore*: Duration

    appSpecificWeight*: float
    ipColocationFactorWeight*: float
    ipColocationFactorThreshold*: float
    behaviourPenaltyWeight*: float
    behaviourPenaltyDecay*: float

  GossipSub* = ref object of FloodSub
    parameters*: GossipSubParams
    mesh*: PeerTable                           # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable                         # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable                      # peers that are subscribed to a topic
    explicit*: PeerTable                       # directpeers that we keep alive explicitly
    explicitPeers*: HashSet[string]            # explicit (always connected/forward) peers
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

proc init*(_: type[GossipSubParams]): GossipSubParams =
  GossipSubParams(
      pruneBackoff: 1.minutes,
      floodPublish: true,
      gossipFactor: 0.25,
      dScore: 4,
      dOut: 2,
      gossipThreshold: -10,
      publishThreshold: -100,
      graylistThreshold: -10000,
      opportunisticGraftThreshold: 1,
      decayInterval: 1.seconds,
      decayToZero: 0.01,
      retainScore: 10.seconds,
      appSpecificWeight: 1.0,
      ipColocationFactorWeight: 0.0,
      ipColocationFactorThreshold: 1.0,
      behaviourPenaltyWeight: -1.0,
      behaviourPenaltyDecay: 0.999,
    )

proc validateParameters*(parameters: GossipSubParams): Result[void, cstring] =
  if  (parameters.dOut >= GossipSubDlo) or 
      (parameters.dOut > (GossipSubD div 2)):
    err("gossipsub: dOut parameter error, Number of outbound connections to keep in the mesh. Must be less than D_lo and at most D/2")
  elif parameters.gossipThreshold >= 0:
    err("gossipsub: gossipThreshold parameter error, Must be < 0")
  elif parameters.publishThreshold >= parameters.gossipThreshold:
    err("gossipsub: publishThreshold parameter error, Must be < gossipThreshold")
  elif parameters.graylistThreshold >= parameters.publishThreshold:
    err("gossipsub: graylistThreshold parameter error, Must be < publishThreshold")
  elif parameters.acceptPXThreshold < 0:
    err("gossipsub: acceptPXThreshold parameter error, Must be >= 0")
  elif parameters.opportunisticGraftThreshold < 0:
    err("gossipsub: opportunisticGraftThreshold parameter error, Must be >= 0")
  elif parameters.decayToZero > 0.5 or parameters.decayToZero <= 0.0:
    err("gossipsub: decayToZero parameter error, Should be close to 0.0")
  elif parameters.appSpecificWeight < 0:
    err("gossipsub: appSpecificWeight parameter error, Must be positive")
  elif parameters.ipColocationFactorWeight > 0:
    err("gossipsub: ipColocationFactorWeight parameter error, Must be negative or 0")
  elif parameters.ipColocationFactorThreshold < 1.0:
    err("gossipsub: ipColocationFactorThreshold parameter error, Must be at least 1")
  elif parameters.behaviourPenaltyWeight >= 0:
    err("gossipsub: behaviourPenaltyWeight parameter error, Must be negative")
  elif parameters.behaviourPenaltyDecay < 0 or parameters.behaviourPenaltyDecay >= 1:
    err("gossipsub: behaviourPenaltyDecay parameter error, Must be between 0 and 1")
  else:
    ok()

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
  g.codecs &= GossipSubCodec
  g.codecs &= GossipSubCodec_10

proc replenishFanout(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  trace "about to replenish fanout"

  if g.fanout.peers(topic) < GossipSubDLo:
    trace "replenishing fanout", peers = g.fanout.peers(topic)
    if topic in g.gossipsub:
      for peer in g.gossipsub[topic]:
        if g.fanout.addPeer(topic, peer):
          if g.fanout.peers(topic) == GossipSubD:
            break

  libp2p_gossipsub_peers_per_topic_fanout
    .set(g.fanout.peers(topic).int64, labelValues = [topic])

  trace "fanout replenished with peers", peers = g.fanout.peers(topic)

proc rebalanceMesh(g: GossipSub, topic: string) {.async.} =
  trace "about to rebalance mesh"
  # create a mesh topic that we're subscribing to

  var
    grafts, prunes: seq[PubSubPeer]

  if g.mesh.peers(topic) < GossipSubDlo:
    trace "replenishing mesh", topic, peers = g.mesh.peers(topic)
    # replenish the mesh if we're below GossipSubDlo
    var newPeers = toSeq(
      g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
      g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
    )

    logScope:
      topic = topic
      meshPeers = g.mesh.peers(topic)
      newPeers = newPeers.len

    shuffle(newPeers)

    trace "getting peers", topic, peers = newPeers.len

    for peer in newPeers:
      # send a graft message to the peer
      grafts.add(peer)
      if g.mesh.addPeer(topic, peer):
        peer.grafted(topic)
      trace "got peer", peer = $peer

  if g.mesh.peers(topic) > GossipSubDhi:
    # prune peers if we've gone over
    # gather peers
    var mesh = toSeq(g.mesh[topic])
    # shuffle anyway, we might not use score
    shuffle(mesh) 
    # sort peers by score
    mesh.sort(proc (x, y: PubSubPeer): int =
      let
        peerx = x.score()
        peery = y.score()
      if peerx < peery: -1
      elif peerx == peery: 0
      else: 1)

    trace "about to prune mesh", mesh = mesh.len
    for peer in mesh:
      if g.mesh.peers(topic) <= GossipSubD:
        break

      trace "pruning peers", peers = g.mesh.peers(topic)
      # send a graft message to the peer
      peer.pruned(topic)
      g.mesh.removePeer(topic, peer)
      prunes.add(peer)

  libp2p_gossipsub_peers_per_topic_gossipsub
    .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

  libp2p_gossipsub_peers_per_topic_fanout
    .set(g.fanout.peers(topic).int64, labelValues = [topic])

  libp2p_gossipsub_peers_per_topic_mesh
    .set(g.mesh.peers(topic).int64, labelValues = [topic])

  # Send changes to peers after table updates to avoid stale state
  for p in grafts:
    await p.sendGraft(@[topic])
  for p in prunes:
    await p.sendPrune(@[topic])

  trace "mesh balanced, got peers", peers = g.mesh.peers(topic),
                                    topicId = topic

proc dropFanoutPeers(g: GossipSub) =
  # drop peers that we haven't published to in
  # GossipSubFanoutTTL seconds
  let now = Moment.now()
  for topic in toSeq(g.lastFanoutPubSub.keys):
    let val = g.lastFanoutPubSub[topic]
    if now > val:
      g.fanout.del(topic)
      g.lastFanoutPubSub.del(topic)
      trace "dropping fanout topic", topic

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(topic).int64, labelValues = [topic])

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

    for peer in allPeers:
      if result.len >= GossipSubD:
        trace "got gossip peers", peers = result.len
        break

      if peer in gossipPeers:
        continue

      if peer.id notin result:
        result[peer.id] = controlMsg

      result[peer.id].ihave.add(ihave)

proc updateScores(g: GossipSub) = # avoid async
  debug "updating scores", peers = g.peers.len
  
  let now = Moment.now()

  for id, peer in g.peers:
    # TODO

    # Per topic
    for topic in peer.topics:
      # Defect on purpose, no magic here please, this should not fail!
      let topicParams = g.topics[topic].parameters
      var info = peer.topicInfos[topic]
      if info.inMesh:
        info.meshTime = now - info.graftTime
        if info.meshTime > topicParams.meshMessageDeliveriesActivation:
          info.meshMessageDeliveriesActive = true
      # debug assert to check nim compiler is doing what we are asking...
      assert(peer.topicInfos[topic].meshTime == info.meshTime)

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat"

      g.updateScores()

      for t in toSeq(g.topics.keys):
        await g.rebalanceMesh(t)

      g.dropFanoutPeers()

      # replenish known topics to the fanout
      for t in toSeq(g.fanout.keys):
        g.replenishFanout(t)

      let peers = g.getGossipPeers()
      var sent: seq[Future[void]]
      for peer in peers.keys:
        if peer in g.peers:
          sent &= g.peers[peer].send(RPCMsg(control: some(peers[peer])))
      checkFutures(await allFinished(sent))

      g.mcache.shift() # shift the cache
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception ocurred in gossipsub heartbeat", exc = exc.msg

    await sleepAsync(GossipSubHeartbeatInterval)

method handleDisconnect*(g: GossipSub, peer: PubSubPeer) =
  ## handle peer disconnects
  procCall FloodSub(g).handleDisconnect(peer)

  for t in toSeq(g.gossipsub.keys):
    g.gossipsub.removePeer(t, peer)

    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.peers(t).int64, labelValues = [t])

  for t in toSeq(g.mesh.keys):
    g.mesh.removePeer(t, peer)

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.peers(t).int64, labelValues = [t])

  for t in toSeq(g.fanout.keys):
    g.fanout.removePeer(t, peer)

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(t).int64, labelValues = [t])

  if peer.peerInfo.maintain:
    for t in toSeq(g.explicit.keys):
      g.explicit.removePeer(t, peer)
    
    g.explicitPeers.excl(peer.id)

method subscribePeer*(p: GossipSub,
                      conn: Connection) =
  procCall PubSub(p).subscribePeer(conn)
  asyncCheck p.handleConn(conn, GossipSubCodec)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe, async.} =
  await procCall FloodSub(g).subscribeTopic(topic, subscribe, peerId)

  let peer = g.peers.getOrDefault(peerId)
  if peer == nil:
    debug "subscribeTopic on a nil peer!"
    return

  if subscribe:
    trace "adding subscription for topic", peer = peerId, name = topic
    # subscribe remote peer to the topic
    discard g.gossipsub.addPeer(topic, peer)
    if peerId in g.explicitPeers:
      discard g.explicit.addPeer(topic, peer)
  else:
    trace "removing subscription for topic", peer = peerId, name = topic
    # unsubscribe remote peer from the topic
    g.gossipsub.removePeer(topic, peer)
    g.mesh.removePeer(topic, peer)
    g.fanout.removePeer(topic, peer)
    if peerId in g.explicitPeers:
      g.explicit.removePeer(topic, peer)

  libp2p_gossipsub_peers_per_topic_mesh
    .set(g.mesh.peers(topic).int64, labelValues = [topic])
  libp2p_gossipsub_peers_per_topic_fanout
    .set(g.fanout.peers(topic).int64, labelValues = [topic])
  libp2p_gossipsub_peers_per_topic_gossipsub
    .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

  trace "gossip peers", peers = g.gossipsub.peers(topic), topic

  # also rebalance current topic if we are subbed to
  if topic in g.topics:
    await g.rebalanceMesh(topic)

proc handleGraft(g: GossipSub,
                 peer: PubSubPeer,
                 grafts: seq[ControlGraft]): seq[ControlPrune] =
  for graft in grafts:
    let topic = graft.topicID
    trace "processing graft message", topic, peer = $peer

    # It is an error to GRAFT on a explicit peer
    if peer.peerInfo.maintain:
      trace "attempt to graft an explicit peer",  peer=peer.id, 
                                                  topicID=graft.topicID
      # and such an attempt should be logged and rejected with a PRUNE
      result.add(ControlPrune(topicID: graft.topicID))
      continue

    # If they send us a graft before they send us a subscribe, what should
    # we do? For now, we add them to mesh but don't add them to gossipsub.
    if topic in g.topics:
      if g.mesh.peers(topic) < GossipSubDHi:
        # In the spec, there's no mention of DHi here, but implicitly, a
        # peer will be removed from the mesh on next rebalance, so we don't want
        # this peer to push someone else out
        if g.mesh.addPeer(topic, peer):
          peer.grafted(topic)
          g.fanout.removePeer(topic, peer)
        else:
          trace "Peer already in mesh", topic, peer = $peer
      else:
        result.add(ControlPrune(topicID: topic))
    else:
      result.add(ControlPrune(topicID: topic))

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.peers(topic).int64, labelValues = [topic])

proc handlePrune(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    trace "processing prune message", peer = $peer,
                                      topicID = prune.topicID

    peer.pruned(prune.topicID)
    g.mesh.removePeer(prune.topicID, peer)
    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.peers(prune.topicID).int64, labelValues = [prune.topicID])

proc handleIHave(g: GossipSub,
                 peer: PubSubPeer,
                 ihaves: seq[ControlIHave]): ControlIWant =
  for ihave in ihaves:
    trace "processing ihave message", peer = $peer,
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
      trace "processing iwant message", peer = $peer,
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
      var toSendPeers: HashSet[PubSubPeer]
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
              try:
                await h(t, msg.data)                 # trigger user provided handler
              except CatchableError as exc:
                trace "exception in message handler", exc = exc.msg

      # forward the message to all peers interested in it
      let (published, failed) = await g.sendHelper(toSendPeers, m.messages)
      for p in failed:
        let peer = g.peers.getOrDefault(p)
        if not isNil(peer):
          g.handleDisconnect(peer) # cleanup failed peers

      trace "forwared message to peers", peers = published.len

    var respControl: ControlMessage
    if m.control.isSome:
      let control = m.control.get()
      g.handlePrune(peer, control.prune)

      respControl.iwant.add(g.handleIHave(peer, control.ihave))
      respControl.prune.add(g.handleGraft(peer, control.graft))
      let messages = g.handleIWant(peer, control.iwant)

      if respControl.graft.len > 0 or respControl.prune.len > 0 or
         respControl.ihave.len > 0 or respControl.iwant.len > 0:
        await peer.send(
          RPCMsg(control: some(respControl), messages: messages))

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  await procCall PubSub(g).subscribe(topic, handler)
  
  # if we have a fanout on this topic break it
  if topic in g.fanout:
    g.fanout.del(topic)
  
  await g.rebalanceMesh(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) {.async.} =
  await procCall PubSub(g).unsubscribe(topics)

  for pair in topics:
    let topic = pair.topic
    if topic in g.mesh:
      let peers = g.mesh.getOrDefault(topic)
      g.mesh.del(topic)

      for peer in peers:
        peer.pruned(topic)
        await peer.sendPrune(@[topic])

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data)
  trace "about to publish message on topic", name = topic,
                                             data = data.shortLog
  # directly copy explicit peers
  # as we will always publish to those
  var peers = initHashSet[PubSubPeer]()
  if topic.len <= 0: # data could be 0/empty
    return 0

  if g.parameters.floodPublish:
    for id, peer in g.peers:
      if  topic in peer.topics and
          peer.score() >= g.parameters.publishThreshold:
        debug "publish: including flood/high score peer", peer = id
        peers.incl(peer)

  # add always direct peers
  peers.incl(g.explicit.getOrDefault(topic))

  if topic in g.topics: # if we're subscribed use the mesh
    peers.incl(g.mesh.getOrDefault(topic))
  else: # not subscribed, send to fanout peers
    # try optimistically
    peers.incl(g.fanout.getOrDefault(topic))
    if peers.len == 0:
      # ok we had nothing.. let's try replenish inline
      g.replenishFanout(topic)
      peers.incl(g.fanout.getOrDefault(topic))

    # even if we couldn't publish,
    # we still attempted to publish
    # on the topic, so it makes sense
    # to update the last topic publish
    # time
    g.lastFanoutPubSub[topic] = Moment.fromNow(GossipSubFanoutTTL)

  inc g.msgSeqno
  let
    msg = Message.init(g.peerInfo, data, topic, g.msgSeqno, g.sign)
    msgId = g.msgIdProvider(msg)

  trace "created new message", msg

  trace "publishing on topic", topic, peers = peers.len
  if msgId notin g.mcache:
    g.mcache.put(msgId, msg)

  let (published, failed) = await g.sendHelper(peers, @[msg])
  for p in failed:
    let peer = g.peers.getOrDefault(p)
    if not isNil(peer):
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

  g.parameters.validateParameters().tryGet()

  randomize()
  g.mcache = newMCache(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[PubSubPeer]]()     # meshes - topic to peer
  g.fanout = initTable[string, HashSet[PubSubPeer]]()   # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[PubSubPeer]]()# topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Moment]()  # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]()   # pending control messages
  g.heartbeatLock = newAsyncLock()
