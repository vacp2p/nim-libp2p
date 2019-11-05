## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sets, options, sequtils
import chronos, chronicles
import pubsub,
       floodsub,
       pubsubpeer,
       mcache,
       timedcache,
       rpc/[messages, message],
       ../../crypto/crypto,
       ../protocol,
       ../../peerinfo,
       ../../connection,
       ../../peer

logScope:
  topic = "GossipSub"

const GossipSubCodec = "/meshsub/1.0.0"

# overlay parameters
const GossipSubD   = 6
const GossipSubDlo = 4
const GossipSubDhi = 12

# gossip parameters
const GossipSubHistoryLength = 5
const GossipSubHistoryGossip = 3

# heartbeat interval
const GossipSubHeartbeatInitialDelay = 100.millis
const GossipSubHeartbeatInterval     = 1.seconds

# fanout ttl
const GossipSubFanoutTTL = 60.seconds

type
  GossipSub* = ref object of FloodSub
    mesh*: Table[string, HashSet[string]] # meshes - topic to peer
    fanout*: Table[string, HashSet[string]] # fanout - topic to peer
    gossipsub*: Table[string, HashSet[string]] # topic to peer map of all gossipsub peers
    lastFanoutPubSub*: Table[string, Duration] # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]] # pending gossip
    control*: Table[string, ControlMessage] # pending control messages
    mcache*: MCache # messages cache
    heartbeatCancel*: Future[void] # cancelation future for heartbeat interval

method init(g: GossipSub) = 
  proc handler(conn: Connection, proto: string) {.async, gcsafe.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await g.handleConn(conn, proto)

  g.handler = handler
  g.codec = GossipSubCodec

method handleDisconnect(g: GossipSub, peer: PubSubPeer) {.async, gcsafe.} = 
  ## handle peer disconnects
  await procCall FloodSub(g).handleDisconnect(peer)
  for t in g.gossipsub.keys:
    g.gossipsub[t].excl(peer.id)
  
  for t in g.mesh.keys:
    g.mesh[t].excl(peer.id)

  for t in g.fanout.keys:
    g.fanout[t].excl(peer.id)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.gcsafe.} =
    procCall PubSub(g).subscribeTopic(topic, subscribe, peerId)

    if topic notin g.gossipsub:
      g.gossipsub[topic] = initHashSet[string]()

    if subscribe:
      trace "adding subscription for topic", peer = peerId, name = topic
      # subscribe the peer to the topic
      g.gossipsub[topic].incl(peerId)
    else:
      trace "removing subscription for topic", peer = peerId, name = topic
      # unsubscribe the peer from the topic
      g.gossipsub[topic].excl(peerId)

method rpcHandler(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsgs: seq[RPCMsg]) {.async, gcsafe.} = 
  await procCall PubSub(g).rpcHandler(peer, rpcMsgs)

  trace "processing RPC message", peer = peer.id, msg = rpcMsgs
  for m in rpcMsgs:                                # for all RPC messages
    trace "processing message", msg = rpcMsgs
    if m.subscriptions.len > 0:                    # if there are any subscriptions
      for s in m.subscriptions:                    # subscribe/unsubscribe the peer for each topic
        g.subscribeTopic(s.topic, s.subscribe, peer.id)

    if m.messages.len > 0:                         # if there are any messages
      var toSendPeers: HashSet[string] = initHashSet[string]()
      for msg in m.messages:                       # for every message
        for t in msg.topicIDs:                     # for every topic in the message
          if t in g.topics:
            toSendPeers.incl(g.mesh[t])            # get all the peers interested in this topic

        # forward the message to all peers interested in it
        for p in toSendPeers:
          if p in g.peers and g.peers[p].id != peer.id:
            await g.peers[p].send(@[RPCMsg(messages: m.messages)])

    var respControl: ControlMessage
    if m.control.isSome:
      var control: ControlMessage = m.control.get()
      for graft in control.graft:
        trace "processing graft message", peer = peer.id, topicID = graft.topicID
        if graft.topicID in g.topics:
          if g.mesh.len < GossipSubD:
            g.mesh[graft.topicID].incl(peer.id)
          else:
            g.gossipsub[graft.topicID].incl(peer.id)
        else:
          respControl.prune.add(ControlPrune(topicID: graft.topicID))

      for prune in control.prune:
        trace "processing prune message", peer = peer.id, topicID = prune.topicID
        if prune.topicID in g.mesh:
          g.mesh[prune.topicID].excl(peer.id)

      var iWant: ControlIWant
      for ihave in control.ihave:
        if ihave.topicID in g.mesh:
          for m in ihave.messageIDs:
            if m notin g.seen:
              iWant.messageIDs.add(m)

      if iWant.messageIDs.len > 0:
        respControl.iwant.add(iWant)

      var messages: seq[Message]
      for iwant in control.iwant:
        for mid in iwant.messageIDs:
          let msg = g.mcache.get(mid)
          if msg.isSome:
            messages.add(msg.get())

      if respControl.graft.len > 0 or respControl.prune.len > 0 or
         respControl.ihave.len > 0 or respControl.iwant.len > 0:
        await peer.send(@[RPCMsg(control: some(respControl), messages: messages)])

proc replenishFanout(g: GossipSub, topic: string) {.async, gcsafe.} = 
  ## get peers for topic
  if topic notin g.fanout:
    g.fanout[topic] = initHashSet[string]()

  if g.fanout[topic].len < GossipSubD:
    for p in g.gossipsub[topic]:
      if not g.fanout[topic].containsOrIncl(p):
        if g.fanout[topic].len == GossipSubD:
          return

proc rebalanceMesh(g: GossipSub, topic: string) {.async, gcsafe.} = 
  trace "rebalancing mesh"
  # create a mesh topic that we're subscribing to
  if topic notin g.mesh:
    g.mesh[topic] = initHashSet[string]()

  if g.mesh[topic].len < GossipSubDlo:
    # replenish the mesh if we're bellow GossipSubDlo
    while g.mesh[topic].len < GossipSubD:
      trace "gattering peers", peers = g.mesh[topic].len
      var id: string
      if topic in g.fanout and g.fanout[topic].len > 0:
        id = g.fanout[topic].pop()
        trace "got fanout peer", peer = id
      elif topic in g.gossipsub and g.gossipsub[topic].len > 0:
        id = g.gossipsub[topic].pop()
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
  if g.mesh[topic].len > GossipSubDhi:
    while g.mesh[topic].len > GossipSubD:
      trace "pruning peers", peers = g.mesh[topic].len
      for id in g.mesh[topic]:
        g.mesh[topic].excl(id)

        if id in g.peers:
          let p = g.peers[id]
          # send a graft message to the peer
          await p.sendPrune(@[topic])

proc heatbeat(g: GossipSub) {.async, gcsafe.} = 
  trace "running heartbeat"
  await sleepAsync(GossipSubHeartbeatInitialDelay)
  for t in g.mesh.keys:
    await g.rebalanceMesh(t)

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) {.async, gcsafe.} =
  await procCall PubSub(g).subscribe(topic, handler)
  asyncCheck g.rebalanceMesh(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) {.async, gcsafe.} = 
  await procCall PubSub(g).unsubscribe(topics)

  for pair in topics:
    let topic = pair.topic
    if topic in g.mesh:
      let peers = g.mesh[topic]
      g.mesh.del(topic)
      for id in peers:
        let p = g.peers[id]
        await p.sendPrune(@[topic])

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte]) {.async, gcsafe.} =
  await procCall PubSub(g).publish(topic, data)

  trace "about to publish message on topic", name = topic, data = data.toHex()
  if data.len > 0 and topic.len > 0:
    var peers: HashSet[string]
    if topic in g.topics: # if we're subscribed to the topic attempt to build a mesh
      await g.rebalanceMesh(topic)
      peers = g.mesh[topic]
    else: # send to fanout peers
      await g.replenishFanout(topic)
      if topic in g.fanout:
        peers = g.fanout[topic]

    for p in peers:
      trace "publishing on topic", name = topic
      let msg = newMessage(g.peerInfo.peerId.get(), data, topic)
      g.mcache.put(msg)
      await g.peers[p].send(@[RPCMsg(messages: @[msg])])

method subscribeToPeer*(f: GossipSub, 
                        conn: Connection) {.async, gcsafe.} =
  await f.handleConn(conn, GossipSubCodec)

method initPubSub(g: GossipSub) =
  procCall FloodSub(g).initPubSub()

  g.mcache = newMCache(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[string]]() # meshes - topic to peer
  g.fanout = initTable[string, HashSet[string]]() # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[string]]() # topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Duration]() # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]() # pending control messages

  # setup the heartbeat interval
  g.heartbeatCancel = addInterval(GossipSubHeartbeatInterval,
                                  proc (arg: pointer = nil) {.gcsafe, locks: 0.} =
                                    asyncCheck g.heatbeat)
