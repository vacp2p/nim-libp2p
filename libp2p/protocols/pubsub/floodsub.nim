## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils, tables, options, sets, strutils
import chronos, chronicles
import pubsub,
       pubsubpeer,
       rpcmsg,
       ../../crypto/crypto,
       ../../connection,
       ../../peerinfo,
       ../../peer

logScope:
  topic = "FloodSub"

const FloodSubCodec* = "/floodsub/1.0.0"

type
  FloodSub* = ref object of PubSub
    peers*: Table[string, PubSubPeer] # peerid to peer map
    peerTopics*: Table[string, HashSet[string]] # topic to remote peer map

proc sendSubs(f: FloodSub,
              peer: PubSubPeer,
              topics: seq[string],
              subscribe: bool) {.async, gcsafe.} =
  ## send subscriptions to remote peer
  trace "sending subscriptions", peer = peer.id, subscribe = subscribe
  var msg: RPCMsg
  for t in topics:
    trace "sending topic", peer = peer.id, subscribe = subscribe, topicName = t
    msg.subscriptions.add(SubOpts(topic: t, subscribe: subscribe))

  await peer.send(@[msg])

proc subscribeTopic(f: FloodSub, topic: string, subscribe: bool, peerId: string) {.gcsafe.} =
    if not f.peerTopics.contains(topic):
      f.peerTopics[topic] = initSet[string]()

    if subscribe:
      trace "adding subscription for topic", peer = peerId, name = topic
      # subscribe the peer to the topic
      f.peerTopics[topic].incl(peerId)
    else:
      trace "removing subscription for topic", peer = peerId, name = topic
      # unsubscribe the peer from the topic
      f.peerTopics[topic].excl(peerId)

proc rpcHandler(f: FloodSub,
                peer: PubSubPeer,
                rpcMsgs: seq[RPCMsg]) {.async, gcsafe.} =
  ## method called by a PubSubPeer every
  ## time it receives an RPC message
  ##
  ## The RPC message might contain subscriptions
  ## or messages forwarded to this peer
  ##

  trace "processing RPC message", peer = peer.id, msg = rpcMsgs
  for m in rpcMsgs:                                # for all RPC messages
    trace "processing message", msg = rpcMsgs
    if m.subscriptions.len > 0:                    # if there are any subscriptions
      for s in m.subscriptions:                    # subscribe/unsubscribe the peer for each topic
        let id = peer.id

        f.subscribeTopic(s.topic, s.subscribe, id)

      # send subscriptions to every peer
      for p in f.peers.values:
        if p.id != peer.id:
          await p.send(@[RPCMsg(subscriptions: m.subscriptions)])

    var toSendPeers: HashSet[string] = initSet[string]()
    if m.messages.len > 0:                         # if there are any messages
      for msg in m.messages:                       # for every message
        for t in msg.topicIDs:                     # for every topic in the message
          toSendPeers.incl(f.peerTopics[t])        # get all the peers interested in this topic
          if f.topics.contains(t):                 # check that we're subscribed to it
            for h in f.topics[t].handler:
              await h(t, msg.data) # trigger user provided handler

        # forward the message to all peers interested in it
        for p in toSendPeers:
          if p in f.peers and f.peers[p].id != peer.id:
            await f.peers[p].send(@[RPCMsg(messages: m.messages)])

proc handleConn(f: FloodSub,
                conn: Connection) {.async, gcsafe.} =
  ## handle incoming/outgoing connections
  ##
  ## this proc will:
  ## 1) register a new PubSubPeer for the connection
  ## 2) register a handler with the peer;
  ##    this handler gets called on every rpc message 
  ##    that the peer receives
  ## 3) ask the peer to subscribe us to every topic
  ##    that we're interested in
  ## 

  if conn.peerInfo.peerId.isNone:
    trace "no valid PeerId for peer"
    return

  # create new pubsub peer
  var peer = newPubSubPeer(conn, proc (peer: PubSubPeer, 
                                       msgs: seq[RPCMsg]) {.async, gcsafe.} =
                                          # call floodsub rpc handler
                                          await f.rpcHandler(peer, msgs))

  trace "created new pubsub peer", id = peer.id

  f.peers[peer.id] = peer
  let topics = toSeq(f.topics.keys)
  await f.sendSubs(peer, topics, true)
  let handlerFut = peer.handle() # spawn peer read loop
  handlerFut.addCallback(
    proc(udata: pointer = nil) {.gcsafe.} = 
      trace "pubsub peer handler ended, cleaning up",
        peer = conn.peerInfo.peerId.get().pretty
      f.peers.del(peer.id)
  )

method init(f: FloodSub) = 
  proc handler(conn: Connection, proto: string) {.async, gcsafe.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await f.handleConn(conn)

  f.handler = handler
  f.codec = FloodSubCodec

method subscribeToPeer*(f: FloodSub, conn: Connection) {.async, gcsafe.} =
  await f.handleConn(conn)

method publish*(f: FloodSub,
                topic: string,
                data: seq[byte]) {.async, gcsafe.} =
  await procCall PubSub(f).publish(topic, data)

  trace "about to publish message on topic", name = topic, data = data.toHex()
  if data.len > 0 and topic.len > 0:
    let msg = makeMessage(f.peerInfo.peerId.get(), data, topic)
    if topic in f.peerTopics:
      trace "publishing on topic", name = topic
      for p in f.peerTopics[topic]:
        trace "publishing message", name = topic, peer = p, data = data
        await f.peers[p].send(@[RPCMsg(messages: @[msg])])

method subscribe*(f: FloodSub,
                  topic: string,
                  handler: TopicHandler) {.async, gcsafe.} =
  await procCall PubSub(f).subscribe(topic, handler)

  f.subscribeTopic(topic, true, f.peerInfo.peerId.get().pretty)
  for p in f.peers.values:
    await f.sendSubs(p, @[topic], true)

method unsubscribe*(f: FloodSub, 
                    topics: seq[TopicPair]) {.async, gcsafe.} = 
  await procCall PubSub(f).unsubscribe(topics)
  for p in f.peers.values:
    await f.sendSubs(p, topics.mapIt(it.topic).deduplicate(), false)

method initPubSub*(f: FloodSub) = 
  f.peers = initTable[string, PubSubPeer]()
  f.topics = initTable[string, Topic]()
  f.peerTopics = initTable[string, HashSet[string]]()
  f.init()
