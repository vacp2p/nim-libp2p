# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[sets, hashes, tables]
import chronos, chronicles, metrics
import
  ./pubsub,
  ./pubsubpeer,
  ./timedcache,
  ./peertable,
  ./rpc/[message, messages, protobuf],
  nimcrypto/[hash, sha2],
  ../../crypto/crypto,
  ../../stream/connection,
  ../../peerid,
  ../../peerinfo,
  ../../utility

## Simple flood-based publishing.

logScope:
  topics = "libp2p floodsub"

const FloodSubCodec* = "/floodsub/1.0.0"

type FloodSub* = ref object of PubSub
  floodsub*: PeerTable # topic to remote peer map
  seen*: TimedCache[SaltedId]
    # Early filter for messages recently observed on the network
    # We use a salted id because the messages in this cache have not yet
    # been validated meaning that an attacker has greater control over the
    # hash key and therefore could poison the table
  seenSalt: array[32, byte] # random data used as salt

proc salt*(f: FloodSub, msgId: MessageId): SaltedId =
  var hash: sha256
  hash.init()
  hash.update(f.seenSalt)
  hash.update(msgId)
  SaltedId(data: hash.finish())

proc hasSeen*(f: FloodSub, saltedId: SaltedId): bool =
  saltedId in f.seen

proc addSeen*(f: FloodSub, saltedId: SaltedId): bool =
  # Return true if the message has already been seen
  f.seen.put(saltedId)

proc firstSeen*(f: FloodSub, saltedId: SaltedId): Moment =
  f.seen.addedAt(saltedId)

proc handleSubscribe(f: FloodSub, peer: PubSubPeer, topic: string, subscribe: bool) =
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

  if subscribe and not (isNil(f.subscriptionValidator)) and
      not (f.subscriptionValidator(topic)):
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

method rpcHandler*(
    f: FloodSub, peer: PubSubPeer, data: sink seq[byte]
) {.async: (raises: [CancelledError, PeerMessageDecodeError, PeerRateLimitError]).} =
  var rpcMsg = decodeRpcMsg(data).valueOr:
    debug "failed to decode msg from peer", peer, err = error
    raise newException(PeerMessageDecodeError, "Peer msg couldn't be decoded")

  trace "decoded msg from peer", peer, rpcMsg = rpcMsg.shortLog
  # trigger hooks
  peer.recvObservers(rpcMsg)

  for i in 0 ..< min(f.topicsHigh, rpcMsg.subscriptions.len):
    template sub(): untyped =
      rpcMsg.subscriptions[i]

    f.handleSubscribe(peer, sub.topic, sub.subscribe)

  for msg in rpcMsg.messages: # for every message
    let msgIdResult = f.msgIdProvider(msg)
    if msgIdResult.isErr:
      debug "Dropping message due to failed message id generation",
        error = msgIdResult.error
      # TODO: descore peers due to error during message validation (malicious?)
      continue

    let
      msgId = msgIdResult.get
      saltedId = f.salt(msgId)

    if f.addSeen(saltedId):
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
    let topic = msg.topic
    if topic notin f.topics:
      debug "Dropping message due to topic not in floodsub topics", topic, msgId, peer
      continue

    f.floodsub.withValue(topic, peers):
      toSendPeers.incl(peers[])

    await handleData(f, topic, msg.data)

    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    f.broadcast(toSendPeers, RPCMsg.withMessages(msg), MessagePriority.Low)
    trace "Forwared message to peers", peers = toSendPeers.len

  f.updateMetrics(rpcMsg)

method init*(f: FloodSub) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##
    try:
      await f.handleConn(conn, proto)
    except CancelledError as exc:
      trace "floodsub handler cancelled", conn
      raise exc

  f.handler = handler
  f.codec = FloodSubCodec

method publish*(
    f: FloodSub,
    topic: string,
    data: sink seq[byte],
    publishParams: Opt[PublishParams] = Opt.none(PublishParams),
): Future[int] {.async: (raises: []).} =
  handleSelfPublishing(f, topic, data)

  trace "Publishing message on topic", data = data.shortLog, topic

  if topic.len <= 0: # data could be 0/empty
    debug "Empty topic, skipping publish", topic
    return 0

  let peers = f.floodsub.getOrDefault(topic)

  if peers.len == 0:
    debug "No peers for topic, skipping publish", topic
    return 0

  let
    msg =
      if f.anonymize:
        Message.init(Opt.none(PeerInfo), data, topic, Opt.none(uint64), false)
      else:
        inc f.msgSeqno
        Message.init(Opt.some(f.peerInfo), data, topic, Opt.some(f.msgSeqno), f.sign)
    msgId = f.msgIdProvider(msg).valueOr:
      trace "Error generating message id, skipping publish", error = error
      return 0

  trace "Created new message", message = shortLog(msg), peers = peers.len, topic, msgId

  if f.addSeen(f.salt(msgId)):
    # custom msgid providers might cause this
    trace "Dropping already-seen message", msgId, topic
    return 0

  # Try to send to all peers that are known to be interested
  f.broadcast(peers, RPCMsg.withMessages(msg), MessagePriority.Medium)

  when defined(libp2p_expensive_metrics):
    libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "Published message to peers", msgId, topic

  return peers.len

method initPubSub*(f: FloodSub) {.raises: [InitializationError].} =
  procCall PubSub(f).initPubSub()
  f.seen = TimedCache[SaltedId].init(2.minutes)
  hmacDrbgGenerate(f.rng[], f.seenSalt)

  f.init()
