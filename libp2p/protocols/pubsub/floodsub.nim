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
       timedcache,
       rpc/[messages, message],
       ../../crypto/crypto,
       ../../connection,
       ../../peerinfo,
       ../../peer

logScope:
  topic = "FloodSub"

const FloodSubCodec* = "/floodsub/1.0.0"

type
  FloodSub* = ref object of PubSub
    floodsub*: Table[string, HashSet[string]] # topic to remote peer map
    seen*: TimedCache[Message] # list of messages forwarded to peers

proc subscribeTopic*(f: FloodSub,
                     topic: string,
                     subscribe: bool,
                     peerId: string) {.gcsafe.} =
    if topic notin f.floodsub:
      f.floodsub[topic] = initSet[string]()

    if subscribe:
      trace "adding subscription for topic", peer = peerId, name = topic
      # subscribe the peer to the topic
      f.floodsub[topic].incl(peerId)
    else:
      trace "removing subscription for topic", peer = peerId, name = topic
      # unsubscribe the peer from the topic
      f.floodsub[topic].excl(peerId)

method rpcHandler*(f: FloodSub,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async, gcsafe.} =
  trace "processing RPC message", peer = peer.id, msg = rpcMsgs
  for m in rpcMsgs:                                # for all RPC messages
    trace "processing message", msg = rpcMsgs
    if m.subscriptions.len > 0:                    # if there are any subscriptions
      for s in m.subscriptions:                    # subscribe/unsubscribe the peer for each topic
        f.subscribeTopic(s.topic, s.subscribe, peer.id)

    if m.messages.len > 0:                         # if there are any messages
      var toSendPeers: HashSet[string] = initSet[string]()
      for msg in m.messages:                       # for every message
        f.seen.put(msg.msgId, msg)                 # add the message to the seen cache
        for t in msg.topicIDs:                     # for every topic in the message
          if t in f.floodsub:
            toSendPeers.incl(f.floodsub[t])        # get all the peers interested in this topic
          if t in f.topics:                        # check that we're subscribed to it
            for h in f.topics[t].handler:
              await h(t, msg.data)                 # trigger user provided handler

        # forward the message to all peers interested in it
        for p in toSendPeers:
          if p in f.peers and f.peers[p].id != peer.id:
            await f.peers[p].send(@[RPCMsg(messages: m.messages)])

method init(f: FloodSub) = 
  proc handler(conn: Connection, proto: string) {.async, gcsafe.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await f.handleConn(conn, proto)

  f.handler = handler
  f.codec = FloodSubCodec

method subscribeToPeer*(f: FloodSub, 
                        conn: Connection) {.async, gcsafe.} =
  await f.handleConn(conn, FloodSubCodec)

method publish*(f: FloodSub,
                topic: string,
                data: seq[byte]) {.async, gcsafe.} =
  await procCall PubSub(f).publish(topic, data)

  trace "about to publish message on topic", name = topic, data = data.toHex()
  if data.len > 0 and topic.len > 0:
    let msg = newMessage(f.peerInfo.peerId.get(), data, topic)
    if topic in f.floodsub:
      trace "publishing on topic", name = topic
      for p in f.floodsub[topic]:
        trace "publishing message", name = topic, peer = p, data = data
        await f.peers[p].sendMsg(f.peerInfo.peerId.get(), topic, data)

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
  f.floodsub = initTable[string, HashSet[string]]()
  f.seen = newTimedCache[Message]()
  f.init()
