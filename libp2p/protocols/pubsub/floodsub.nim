## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[sequtils, sets, hashes, tables]
import chronos, chronicles, metrics, bearssl
import ./pubsub,
       ./pubsubpeer,
       ./timedcache,
       ./peertable,
       ./rpc/[message, messages],
       ../../crypto/crypto,
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo,
       ../../utility

logScope:
  topics = "libp2p floodsub"

const FloodSubCodec* = "/floodsub/1.0.0"

type
  FloodSub* = ref object of PubSub
    floodsub*: PeerTable      # topic to remote peer map
    seen*: TimedCache[MessageID] # message id:s already seen on the network
    seenSalt*: seq[byte]

proc hasSeen*(f: FloodSub, msgId: MessageID): bool =
  f.seenSalt & msgId in f.seen

proc addSeen*(f: FloodSub, msgId: MessageID): bool =
  # Salting the seen hash helps avoid attacks against the hash function used
  # in the nim hash table
  # Return true if the message has already been seen
  f.seen.put(f.seenSalt & msgId)

proc handleSubscribe*(f: FloodSub,
                      peer: PubsubPeer,
                      topic: string,
                      subscribe: bool) =
  logScope:
    peer
    topic

  # this is a workaround for a race condition
  # that can happen if we disconnect the peer very early
  # in the future we might use this as a test case
  # and eventually remove this workaround
  if subscribe and peer.peerId notin f.peers:
    trace "ignoring unknown peer"
    return

  if subscribe and not(isNil(f.subscriptionValidator)) and not(f.subscriptionValidator(topic)):
    # this is a violation, so warn should be in order
    warn "ignoring invalid topic subscription", topic, peer
    return

  if subscribe:
    trace "adding subscription for topic", peer, topic

    # subscribe the peer to the topic
    f.floodsub.mgetOrPut(topic, HashSet[PubSubPeer]()).incl(peer)
  else:
    f.floodsub.withValue(topic, peers):
      trace "removing subscription for topic", peer, topic

      # unsubscribe the peer from the topic
      peers[].excl(peer)

method unsubscribePeer*(f: FloodSub, peer: PeerId) =
  ## handle peer disconnects
  ##
  trace "unsubscribing floodsub peer", peer
  let pubSubPeer = f.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    return

  for _, v in f.floodsub.mpairs():
    v.excl(pubSubPeer)

  procCall PubSub(f).unsubscribePeer(peer)

method rpcHandler*(f: FloodSub,
                   peer: PubSubPeer,
                   rpcMsg: RPCMsg) {.async.} =
  for i in 0..<min(f.topicsHigh, rpcMsg.subscriptions.len):
    template sub: untyped = rpcMsg.subscriptions[i]
    f.handleSubscribe(peer, sub.topic, sub.subscribe)

  for msg in rpcMsg.messages:                         # for every message
    let msgIdResult = f.msgIdProvider(msg)
    if msgIdResult.isErr:
      debug "Dropping message due to failed message id generation",
        error = msgIdResult.error
      # TODO: descore peers due to error during message validation (malicious?)
      continue

    let msgId = msgIdResult.get

    if f.addSeen(msgId):
      trace "Dropping already-seen message", msgId, peer
      continue

    if (msg.signature.len > 0 or f.verifySignature) and not msg.verify():
      # always validate if signature is present or required
      debug "Dropping message due to failed signature verification", msgId, peer
      continue

    if msg.seqno.len > 0 and msg.seqno.len != 8:
      # if we have seqno should be 8 bytes long
      debug "Dropping message due to invalid seqno length", msgId, peer
      continue

    # g.anonymize needs no evaluation when receiving messages
    # as we have a "lax" policy and allow signed messages

    let validation = await f.validate(msg)
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
      if t notin f.topics:
        continue
      f.floodsub.withValue(t, peers): toSendPeers.incl(peers[])

      await handleData(f, t, msg.data)

    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    f.broadcast(toSendPeers, RPCMsg(messages: @[msg]))
    trace "Forwared message to peers", peers = toSendPeers.len

  f.updateMetrics(rpcMsg)

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
      # do not need to propagate CancelledError.
      trace "Unexpected cancellation in floodsub handler", conn
    except CatchableError as exc:
      trace "FloodSub handler leaks an error", exc = exc.msg, conn

  f.handler = handler
  f.codec = FloodSubCodec

method publish*(f: FloodSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(f).publish(topic, data)

  trace "Publishing message on topic", data = data.shortLog, topic

  if topic.len <= 0: # data could be 0/empty
    debug "Empty topic, skipping publish", topic
    return 0

  let peers = f.floodsub.getOrDefault(topic)

  if peers.len == 0:
    debug "No peers for topic, skipping publish", topic
    return 0

  inc f.msgSeqno
  let
    msg =
      if f.anonymize:
        Message.init(none(PeerInfo), data, topic, none(uint64), false)
      else:
        Message.init(some(f.peerInfo), data, topic, some(f.msgSeqno), f.sign)
    msgIdResult = f.msgIdProvider(msg)

  if msgIdResult.isErr:
    trace "Error generating message id, skipping publish",
      error = msgIdResult.error
    return 0

  let msgId = msgIdResult.get

  trace "Created new message",
    msg = shortLog(msg), peers = peers.len, topic, msgId

  if f.addSeen(msgId):
    # custom msgid providers might cause this
    trace "Dropping already-seen message", msgId, topic
    return 0

  # Try to send to all peers that are known to be interested
  f.broadcast(peers, RPCMsg(messages: @[msg]))

  when defined(libp2p_expensive_metrics):
    libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "Published message to peers", msgId, topic

  return peers.len

method initPubSub*(f: FloodSub)
  {.raises: [Defect, InitializationError].} =
  procCall PubSub(f).initPubSub()
  f.seen = TimedCache[MessageID].init(2.minutes)
  f.seenSalt = newSeqUninitialized[byte](sizeof(Hash))
  brHmacDrbgGenerate(f.rng[], f.seenSalt)

  f.init()
