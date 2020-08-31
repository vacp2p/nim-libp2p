## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils, tables, sets, strutils
import chronos, chronicles, metrics
import pubsub,
       pubsubpeer,
       timedcache,
       peertable,
       rpc/[messages, message],
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo

logScope:
  topics = "floodsub"

const FloodSubCodec* = "/floodsub/1.0.0"

type
  FloodSub* = ref object of PubSub
    floodsub*: PeerTable      # topic to remote peer map
    seen*: TimedCache[string] # list of messages forwarded to peers

method subscribeTopic*(f: FloodSub,
                       topic: string,
                       subscribe: bool,
                       peer: PubsubPeer) {.gcsafe.} =
  procCall PubSub(f).subscribeTopic(topic, subscribe, peer)

  if topic notin f.floodsub:
    f.floodsub[topic] = initHashSet[PubSubPeer]()

  if subscribe:
    trace "adding subscription for topic", peer = peer.id, name = topic
    # subscribe the peer to the topic
    f.floodsub[topic].incl(peer)
  else:
    trace "removing subscription for topic", peer = peer.id, name = topic
    # unsubscribe the peer from the topic
    f.floodsub[topic].excl(peer)

method unsubscribePeer*(f: FloodSub, peer: PeerID) =
  ## handle peer disconnects
  ##

  trace "unsubscribing floodsub peer", peer = $peer
  let pubSubPeer = f.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    return

  for t in toSeq(f.floodsub.keys):
    if t in f.floodsub:
      f.floodsub[t].excl(pubSubPeer)

  procCall PubSub(f).unsubscribePeer(peer)

method rpcHandler*(f: FloodSub,
                   peer: PubSubPeer,
                   rpcMsg: RPCMsg) {.async.} =
  await procCall PubSub(f).rpcHandler(peer, rpcMsg)

  if rpcMsg.messages.len > 0:                      # if there are any messages
    var toSendPeers = initHashSet[PubSubPeer]()
    for msg in rpcMsg.messages:                         # for every message
      let msgId = f.msgIdProvider(msg)
      logScope: msgId

      if msgId notin f.seen:
        f.seen.put(msgId)                          # add the message to the seen cache

        if f.verifySignature and not msg.verify(peer.peerId):
          trace "dropping message due to failed signature verification"
          continue

        if not (await f.validate(msg)):
          trace "dropping message due to failed validation"
          continue

        for t in msg.topicIDs:                     # for every topic in the message
          if t in f.floodsub:
            toSendPeers.incl(f.floodsub[t])        # get all the peers interested in this topic

          await handleData(f, t, msg.data)

      # forward the message to all peers interested in it
      f.broadcast(
        toSeq(toSendPeers),
        RPCMsg(messages: rpcMsg.messages))

      trace "forwared message to peers", peers = toSendPeers.len

method init*(f: FloodSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    await f.handleConn(conn, proto)

  f.handler = handler
  f.codec = FloodSubCodec

method publish*(f: FloodSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(f).publish(topic, data)

  if data.len <= 0 or topic.len <= 0:
    trace "topic or data missing, skipping publish"
    return 0

  if topic notin f.floodsub:
    trace "missing peers for topic, skipping publish"
    return

  trace "publishing on topic", name = topic
  inc f.msgSeqno
  let
    msg = Message.init(f.peerInfo, data, topic, f.msgSeqno, f.sign)
    peers = toSeq(f.floodsub.getOrDefault(topic))

  # start the future but do not wait yet
  f.broadcast(
    peers,
    RPCMsg(messages: @[msg]))

  when defined(libp2p_expensive_metrics):
    libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "published message to peers", peers = peers.len,
                                      msg = msg.shortLog()
  return peers.len

method unsubscribe*(f: FloodSub,
                    topics: seq[TopicPair]) {.async.} =
  await procCall PubSub(f).unsubscribe(topics)

  for p in f.peers.values:
    f.sendSubs(p, topics.mapIt(it.topic).deduplicate(), false)

method unsubscribeAll*(f: FloodSub, topic: string) {.async.} =
  await procCall PubSub(f).unsubscribeAll(topic)

  for p in f.peers.values:
    f.sendSubs(p, @[topic], false)

method initPubSub*(f: FloodSub) =
  procCall PubSub(f).initPubSub()
  f.floodsub = initTable[string, HashSet[PubSubPeer]]()
  f.seen = newTimedCache[string](2.minutes)
  f.init()
