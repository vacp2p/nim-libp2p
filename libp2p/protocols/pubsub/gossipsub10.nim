## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: this module is temporary to allow
# for quick switchover fro 1.1 to 1.0.
# This should be removed once 1.1 is stable
# enough.

import std/[options, random, sequtils, sets, tables]
import chronos, chronicles, metrics
import ./pubsub,
       ./floodsub,
       ./pubsubpeer,
       ./peertable,
       ./mcache,
       ./timedcache,
       ./rpc/[messages, message],
       ../protocol,
       ../../stream/connection,
       ../../peerinfo,
       ../../peerid,
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
    mesh*: PeerTable                           # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable                         # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable                      # peers that are subscribed to a topic
    lastFanoutPubSub*: Table[string, Moment]   # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]  # pending gossip
    control*: Table[string, ControlMessage]    # pending control messages
    mcache*: MCache                            # messages cache
    heartbeatFut: Future[void]                 # cancellation future for heartbeat interval
    heartbeatRunning: bool
    heartbeatEvents*: seq[AsyncEvent]
    parameters*: GossipSubParams

  GossipSubParams* = object
    # stubs
    explicit: bool
    pruneBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float64
    dScore*: int
    dOut*: int
    dLazy*: int

    gossipThreshold*: float64
    publishThreshold*: float64
    graylistThreshold*: float64
    acceptPXThreshold*: float64
    opportunisticGraftThreshold*: float64
    decayInterval*: Duration
    decayToZero*: float64
    retainScore*: Duration

    appSpecificWeight*: float64
    ipColocationFactorWeight*: float64
    ipColocationFactorThreshold*: float64
    behaviourPenaltyWeight*: float64
    behaviourPenaltyDecay*: float64

    directPeers*: seq[PeerId]

proc init*(G: type[GossipSubParams]): G = discard

when defined(libp2p_expensive_metrics):
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
    try:
      await g.handleConn(conn, proto)
    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
      trace "Unexpected cancellation in gossipsub handler", conn
    except CatchableError as exc:
      trace "GossipSub handler leaks an error", exc = exc.msg, conn

  g.handler = handler
  g.codec = GossipSubCodec

proc replenishFanout(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  logScope: topic
  trace "about to replenish fanout"

  if g.fanout.peers(topic) < GossipSubDLo:
    trace "replenishing fanout", peers = g.fanout.peers(topic)
    if topic in g.gossipsub:
      for peer in g.gossipsub[topic]:
        if g.fanout.addPeer(topic, peer):
          if g.fanout.peers(topic) == GossipSubD:
            break

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(topic).int64, labelValues = [topic])

  trace "fanout replenished with peers", peers = g.fanout.peers(topic)

method onPubSubPeerEvent*(p: GossipSub, peer: PubsubPeer, event: PubSubPeerEvent) {.gcsafe.} =
  case event.kind
  of PubSubPeerEventKind.Connected:
    discard
  of PubSubPeerEventKind.Disconnected:
    # If a send connection is lost, it's better to remove peer from the mesh -
    # if it gets reestablished, the peer will be readded to the mesh, and if it
    # doesn't, well.. then we hope the peer is going away!
    for _, peers in p.mesh.mpairs():
      peers.excl(peer)
    for _, peers in p.fanout.mpairs():
      peers.excl(peer)

  procCall FloodSub(p).onPubSubPeerEvent(peer, event)


proc rebalanceMesh(g: GossipSub, topic: string) {.async.} =
  logScope:
    topic
    mesh = g.mesh.peers(topic)
    gossipsub = g.gossipsub.peers(topic)

  trace "rebalancing mesh"

  # create a mesh topic that we're subscribing to

  var
    grafts, prunes: seq[PubSubPeer]

  if g.mesh.peers(topic) < GossipSubDlo:
    trace "replenishing mesh", peers = g.mesh.peers(topic)
    # replenish the mesh if we're below Dlo
    grafts = toSeq(
      g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
      g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
    ).filterIt(it.connected)

    shuffle(grafts)

    # Graft peers so we reach a count of D
    grafts.setLen(min(grafts.len, GossipSubD - g.mesh.peers(topic)))

    trace "grafting", grafts = grafts.len

    for peer in grafts:
      if g.mesh.addPeer(topic, peer):
        g.fanout.removePeer(topic, peer)

  if g.mesh.peers(topic) > GossipSubDhi:
    # prune peers if we've gone over Dhi
    prunes = toSeq(g.mesh[topic])
    shuffle(prunes)
    prunes.setLen(prunes.len - GossipSubD) # .. down to D peers

    trace "pruning", prunes = prunes.len
    for peer in prunes:
      g.mesh.removePeer(topic, peer)

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(topic).int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.peers(topic).int64, labelValues = [topic])

  trace "mesh balanced"

  # Send changes to peers after table updates to avoid stale state
  if grafts.len > 0:
    let graft = RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))
    g.broadcast(grafts, graft)
  if prunes.len > 0:
    let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
    g.broadcast(prunes, prune)

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

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

proc getGossipPeers(g: GossipSub): Table[PubSubPeer, ControlMessage] {.gcsafe.} =
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
    if not mids.len > 0:
      continue

    if topic notin g.gossipsub:
      trace "topic not in gossip array, skipping", topic
      continue

    let ihave = ControlIHave(topicID: topic, messageIDs: toSeq(mids))
    for peer in allPeers:
      if result.len >= GossipSubD:
        trace "got gossip peers", peers = result.len
        break

      if peer in gossipPeers:
        continue

      if peer notin result:
        result[peer] = controlMsg

      result[peer].ihave.add(ihave)

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat"

      for t in toSeq(g.topics.keys):
        await g.rebalanceMesh(t)

      g.dropFanoutPeers()

      # replenish known topics to the fanout
      for t in toSeq(g.fanout.keys):
        g.replenishFanout(t)

      let peers = g.getGossipPeers()
      for peer, control in peers:
        g.peers.withValue(peer.peerId, pubsubPeer) do:
          g.send(
            pubsubPeer[],
            RPCMsg(control: some(control)))

      g.mcache.shift() # shift the cache
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "exception ocurred in gossipsub heartbeat", exc = exc.msg

    for trigger in g.heartbeatEvents:
      trace "firing heartbeat event", instance = cast[int](g)
      trigger.fire()

    await sleepAsync(GossipSubHeartbeatInterval)

method unsubscribePeer*(g: GossipSub, peer: PeerID) =
  ## handle peer disconnects
  ##

  trace "unsubscribing gossipsub peer", peer
  let pubSubPeer = g.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    trace "no peer to unsubscribe", peer
    return

  for t in toSeq(g.gossipsub.keys):
    g.gossipsub.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_gossipsub
        .set(g.gossipsub.peers(t).int64, labelValues = [t])

  for t in toSeq(g.mesh.keys):
    g.mesh.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(t).int64, labelValues = [t])

  for t in toSeq(g.fanout.keys):
    g.fanout.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(t).int64, labelValues = [t])

  procCall FloodSub(g).unsubscribePeer(peer)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peer: PubSubPeer) {.gcsafe.} =
  # Skip floodsub - we don't want it to add the peer to `g.floodsub`
  procCall PubSub(g).subscribeTopic(topic, subscribe, peer)

  logScope:
    peer
    topic

  if subscribe:
    trace "peer subscribed to topic"
    # subscribe remote peer to the topic
    discard g.gossipsub.addPeer(topic, peer)
  else:
    trace "peer unsubscribed from topic"
    # unsubscribe remote peer from the topic
    g.gossipsub.removePeer(topic, peer)
    g.mesh.removePeer(topic, peer)
    g.fanout.removePeer(topic, peer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

  trace "gossip peers", peers = g.gossipsub.peers(topic), topic

proc handleGraft(g: GossipSub,
                 peer: PubSubPeer,
                 grafts: seq[ControlGraft]): seq[ControlPrune] =
  for graft in grafts:
    let topic = graft.topicID
    logScope:
      peer
      topic

    trace "peer grafted topic"

      # If they send us a graft before they send us a subscribe, what should
      # we do? For now, we add them to mesh but don't add them to gossipsub.

    if topic in g.topics:
      if g.mesh.peers(topic) < GossipSubDHi:
        # In the spec, there's no mention of DHi here, but implicitly, a
        # peer will be removed from the mesh on next rebalance, so we don't want
        # this peer to push someone else out
        if g.mesh.addPeer(topic, peer):
          g.fanout.removePeer(topic, peer)
        else:
          trace "peer already in mesh"
      else:
        result.add(ControlPrune(topicID: topic))
    else:
      debug "peer grafting topic we're not interested in"
      result.add(ControlPrune(topicID: topic))

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

proc handlePrune(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    trace "peer pruned topic", peer, topic = prune.topicID

    g.mesh.removePeer(prune.topicID, peer)
    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(prune.topicID).int64, labelValues = [prune.topicID])

proc handleIHave(g: GossipSub,
                 peer: PubSubPeer,
                 ihaves: seq[ControlIHave]): ControlIWant =
  for ihave in ihaves:
    trace "peer sent ihave",
      peer, topic = ihave.topicID, msgs = ihave.messageIDs

    if ihave.topicID in g.mesh:
      for m in ihave.messageIDs:
        if m notin g.seen:
          result.messageIDs.add(m)

proc handleIWant(g: GossipSub,
                 peer: PubSubPeer,
                 iwants: seq[ControlIWant]): seq[Message] =
  for iwant in iwants:
    for mid in iwant.messageIDs:
      trace "peer sent iwant", peer, messageID = mid
      let msg = g.mcache.get(mid)
      if msg.isSome:
        result.add(msg.get())

method rpcHandler*(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsg: RPCMsg) {.async.} =
  await procCall PubSub(g).rpcHandler(peer, rpcMsg)

  for msg in rpcMsg.messages:                         # for every message
    let msgId = g.msgIdProvider(msg)

    if g.seen.put(msgId):
      trace "Dropping already-seen message", msgId, peer
      continue

    g.mcache.put(msgId, msg)

    if (msg.signature.len > 0 or g.verifySignature) and not msg.verify():
      # always validate if signature is present or required
      debug "Dropping message due to failed signature verification", msgId, peer
      continue

    if msg.seqno.len > 0 and msg.seqno.len != 8:
      # if we have seqno should be 8 bytes long
      debug "Dropping message due to invalid seqno length", msgId, peer
      continue

    # g.anonymize needs no evaluation when receiving messages
    # as we have a "lax" policy and allow signed messages

    let validation = await g.validate(msg)
    case validation
    of ValidationResult.Reject:
      debug "Dropping message after validation, reason: reject", msgId, peer
      continue
    of ValidationResult.Ignore:
      debug "Dropping message after validation, reason: ignore", msgId, peer
      continue
    of ValidationResult.Accept:
      discard

    var toSendPeers = initHashSet[PubSubPeer]()
    for t in msg.topicIDs:                     # for every topic in the message
      g.floodsub.withValue(t, peers): toSendPeers.incl(peers[])
      g.mesh.withValue(t, peers): toSendPeers.incl(peers[])

      await handleData(g, t, msg.data)

    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    g.broadcast(toSeq(toSendPeers), RPCMsg(messages: @[msg]))
    trace "forwared message to peers", peers = toSendPeers.len, msgId, peer

  if rpcMsg.control.isSome:
    let control = rpcMsg.control.get()
    g.handlePrune(peer, control.prune)

    var respControl: ControlMessage
    respControl.iwant.add(g.handleIHave(peer, control.ihave))
    respControl.prune.add(g.handleGraft(peer, control.graft))
    let messages = g.handleIWant(peer, control.iwant)

    if respControl.graft.len > 0 or respControl.prune.len > 0 or
      respControl.ihave.len > 0 or messages.len > 0:

      trace "sending control message", msg = shortLog(respControl), peer
      g.send(
        peer,
        RPCMsg(control: some(respControl), messages: messages))

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  await procCall PubSub(g).subscribe(topic, handler)
  await g.rebalanceMesh(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) {.async.} =
  await procCall PubSub(g).unsubscribe(topics)

  for (topic, handler) in topics:
    # delete from mesh only if no handlers are left
    if topic notin g.topics:
      if topic in g.mesh:
        let peers = g.mesh[topic]
        g.mesh.del(topic)

        let prune = RPCMsg(
          control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
        g.broadcast(toSeq(peers), prune)

method unsubscribeAll*(g: GossipSub, topic: string) {.async.} =
  await procCall PubSub(g).unsubscribeAll(topic)

  if topic in g.mesh:
    let peers = g.mesh.getOrDefault(topic)
    g.mesh.del(topic)

    let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
    g.broadcast(toSeq(peers), prune)

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data)

  logScope: topic
  trace "Publishing message on topic", data = data.shortLog

  if topic.len <= 0: # data could be 0/empty
    debug "Empty topic, skipping publish"
    return 0

  var peers: HashSet[PubSubPeer]
  if topic in g.topics: # if we're subscribed use the mesh
    peers = g.mesh.getOrDefault(topic)
  else: # not subscribed, send to fanout peers
    # try optimistically
    peers = g.fanout.getOrDefault(topic)
    if peers.len == 0:
      # ok we had nothing.. let's try replenish inline
      g.replenishFanout(topic)
      peers = g.fanout.getOrDefault(topic)

    # even if we couldn't publish,
    # we still attempted to publish
    # on the topic, so it makes sense
    # to update the last topic publish
    # time
    g.lastFanoutPubSub[topic] = Moment.fromNow(GossipSubFanoutTTL)

  if peers.len == 0:
    debug "No peers for topic, skipping publish"
    return 0

  inc g.msgSeqno
  let
    msg =
      if g.anonymize:
        Message.init(none(PeerInfo), data, topic, none(uint64), false)
      else:
        Message.init(some(g.peerInfo), data, topic, some(g.msgSeqno), g.sign)
    msgId = g.msgIdProvider(msg)

  logScope: msgId

  trace "Created new message", msg = shortLog(msg), peers = peers.len

  if g.seen.put(msgId):
    # custom msgid providers might cause this
    trace "Dropping already-seen message"
    return 0

  g.mcache.put(msgId, msg)

  g.broadcast(toSeq(peers), RPCMsg(messages: @[msg]))
  when defined(libp2p_expensive_metrics):
    if peers.len > 0:
      libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "Published message to peers"

  return peers.len

method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  if not g.heartbeatFut.isNil:
    warn "Starting gossipsub twice"
    return

  g.heartbeatRunning = true
  g.heartbeatFut = g.heartbeat()

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"
  if g.heartbeatFut.isNil:
    warn "Stopping gossipsub without starting it"
    return

  # stop heartbeat interval
  g.heartbeatRunning = false
  if not g.heartbeatFut.finished:
    trace "awaiting last heartbeat"
    await g.heartbeatFut
    trace "heartbeat stopped"
    g.heartbeatFut = nil


method initPubSub*(g: GossipSub) =
  procCall FloodSub(g).initPubSub()

  randomize()
  g.mcache = MCache.init(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[PubSubPeer]]()     # meshes - topic to peer
  g.fanout = initTable[string, HashSet[PubSubPeer]]()   # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[PubSubPeer]]()# topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Moment]()  # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]()   # pending control messages
