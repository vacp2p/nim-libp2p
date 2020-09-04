## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sequtils, sets, tables]
import chronos, chronicles, metrics
import ./pubsub,
       ./pubsubpeer,
       ./timedcache,
       ./peertable,
       ./rpc/[message, messages],
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo,
       ../../utility

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

  for _, v in f.floodsub.mpairs():
    v.excl(pubSubPeer)

  procCall PubSub(f).unsubscribePeer(peer)

method rpcHandler*(f: FloodSub,
                   peer: PubSubPeer,
                   rpcMsg: RPCMsg) {.async.} =
  await procCall PubSub(f).rpcHandler(peer, rpcMsg)

  for msg in rpcMsg.messages:                         # for every message
    let msgId = f.msgIdProvider(msg)
    logScope:
      msgId
      peer = peer.id

    if f.seen.put(msgId):
      trace "Dropping already-seen message"
      continue

    if f.verifySignature and not msg.verify(peer.peerId):
      debug "Dropping message due to failed signature verification"
      continue

    if not (await f.validate(msg)):
      trace "Dropping message due to failed validation"
      continue

    var toSendPeers = initHashSet[PubSubPeer]()
    for t in msg.topicIDs:                     # for every topic in the message
      f.floodsub.withValue(t, peers): toSendPeers.incl(peers[])

      await handleData(f, t, msg.data)

    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    f.broadcast(toSeq(toSendPeers), RPCMsg(messages: @[msg]))
    trace "Forwared message to peers", peers = toSendPeers.len

method init*(f: FloodSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##
    try:
      await f.handleConn(conn, proto)
    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
      trace "Unexpected cancellation in floodsub handler"
    except CatchableError as exc:
      trace "FloodSub handler leaks an error", exc = exc.msg

  f.handler = handler
  f.codec = FloodSubCodec

method publish*(f: FloodSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(f).publish(topic, data)

  logScope: topic
  trace "Publishing message on topic", data = data.shortLog

  if topic.len <= 0: # data could be 0/empty
    debug "Empty topic, skipping publish"
    return 0

  let peers = toSeq(f.floodsub.getOrDefault(topic))

  if peers.len == 0:
    debug "No peers for topic, skipping publish"
    return 0

  inc f.msgSeqno
  let
    msg = Message.init(f.peerInfo, data, topic, f.msgSeqno, f.sign)
    msgId = f.msgIdProvider(msg)

  logScope: msgId

  trace "Created new message", msg = shortLog(msg), peers = peers.len

  if f.seen.put(msgId):
    # custom msgid providers might cause this
    trace "Dropping already-seen message"
    return 0

  # Try to send to all peers that are known to be interested
  f.broadcast(peers, RPCMsg(messages: @[msg]))

  when defined(libp2p_expensive_metrics):
    libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "Published message to peers"

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
  f.seen = TimedCache[string].init(2.minutes)
  f.init()
