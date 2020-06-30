## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, hashes, strutils, tables, hashes
import chronos, chronicles, nimcrypto/sha2, metrics
import rpc/[messages, message, protobuf],
       timedcache,
       ../../peerid,
       ../../peerinfo,
       ../../stream/connection,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf,
       ../../utility

logScope:
  topics = "pubsubpeer"

declareCounter(libp2p_pubsub_sent_messages, "number of messages sent", labels = ["id", "topic"])
declareCounter(libp2p_pubsub_received_messages, "number of messages received", labels = ["id", "topic"])
declareCounter(libp2p_pubsub_skipped_received_messages, "number of received skipped messages", labels = ["id"])
declareCounter(libp2p_pubsub_skipped_sent_messages, "number of sent skipped messages", labels = ["id"])

type
  PubSubObserver* = ref object
    onRecv*: proc(peer: PubSubPeer; msgs: var RPCMsg) {.gcsafe, raises: [Defect].}
    onSend*: proc(peer: PubSubPeer; msgs: var RPCMsg) {.gcsafe, raises: [Defect].}

  PubSubPeer* = ref object of RootObj
    proto: string # the protocol that this peer joined from
    sendConn: Connection
    peerInfo*: PeerInfo
    handler*: RPCHandler
    topics*: seq[string]
    sentRpcCache: TimedCache[string] # cache for already sent messages
    recvdRpcCache: TimedCache[string] # cache for already received messages
    refs*: int # refcount of the connections this peer is handling
    onConnect: AsyncEvent
    observers*: ref seq[PubSubObserver] # ref as in smart_ptr

  RPCHandler* = proc(peer: PubSubPeer, msg: seq[RPCMsg]): Future[void] {.gcsafe.}

proc id*(p: PubSubPeer): string = p.peerInfo.id

proc connected*(p: PubSubPeer): bool =
  not(isNil(p.sendConn))

proc `conn=`*(p: PubSubPeer, conn: Connection) =
  if not(isNil(conn)):
    trace "attaching send connection for peer", peer = p.id
    p.sendConn = conn
    p.onConnect.fire()

proc recvObservers(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not(isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not(isNil(obs)): # TODO: should never be nil, but...
        obs.onRecv(p, msg)

proc sendObservers(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not(isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not(isNil(obs)): # TODO: should never be nil, but...
        obs.onSend(p, msg)

proc handle*(p: PubSubPeer, conn: Connection) {.async.} =
  trace "handling pubsub rpc", peer = p.id, closed = conn.closed
  try:
    try:
      while not conn.closed:
        trace "waiting for data", peer = p.id, closed = conn.closed
        let data = await conn.readLp(64 * 1024)
        let digest = $(sha256.digest(data))
        trace "read data from peer", peer = p.id, data = data.shortLog
        if digest in p.recvdRpcCache:
          libp2p_pubsub_skipped_received_messages.inc(labelValues = [p.id])
          trace "message already received, skipping", peer = p.id
          continue

        var msg = decodeRpcMsg(data)
        trace "decoded msg from peer", peer = p.id, msg = msg.shortLog
        # trigger hooks
        p.recvObservers(msg)

        for m in msg.messages:
          for t in m.topicIDs:
            # metrics
            libp2p_pubsub_received_messages.inc(labelValues = [p.id, t])

        await p.handler(p, @[msg])
        p.recvdRpcCache.put(digest)
    finally:
      trace "exiting pubsub peer read loop", peer = p.id
      await conn.close()

  except CatchableError as exc:
    trace "Exception occurred in PubSubPeer.handle", exc = exc.msg

proc send*(p: PubSubPeer, msgs: seq[RPCMsg]) {.async.} =
  for m in msgs.items:
    trace "sending msgs to peer", toPeer = p.id, msgs = $msgs

    # trigger send hooks
    var mm = m # hooks can modify the message
    p.sendObservers(mm)

    let encoded = encodeRpcMsg(mm)
    if encoded.buffer.len <= 0:
      trace "empty message, skipping", peer = p.id
      return

    let digest = $(sha256.digest(encoded.buffer))
    if digest in p.sentRpcCache:
      trace "message already sent to peer, skipping", peer = p.id
      libp2p_pubsub_skipped_sent_messages.inc(labelValues = [p.id])
      continue

    proc sendToRemote() {.async.} =
      try:
        trace "about to send message", peer = p.id,
                                       encoded = digest
        if not p.onConnect.isSet:
          await p.onConnect.wait()

        if p.connected: # this can happen if the remote disconnected
          trace "sending encoded msgs to peer", peer = p.id,
                                                encoded = encoded.buffer.shortLog
          await p.sendConn.writeLp(encoded.buffer)
          p.sentRpcCache.put(digest)

          for m in msgs:
            for mm in m.messages:
              for t in mm.topicIDs:
                # metrics
                libp2p_pubsub_sent_messages.inc(labelValues = [p.id, t])

      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        trace "unable to send to remote", exc = exc.msg
        if not(isNil(p.sendConn)):
          await p.sendConn.close()
          p.sendConn = nil
          p.onConnect.clear()

    # if no connection has been set,
    # queue messages until a connection
    # becomes available
    asyncCheck sendToRemote()

proc sendMsg*(p: PubSubPeer,
              peerId: PeerID,
              topic: string,
              data: seq[byte],
              sign: bool): Future[void] {.gcsafe.} =
  p.send(@[RPCMsg(messages: @[Message.init(p.peerInfo, data, topic, sign)])])

proc sendGraft*(p: PubSubPeer, topics: seq[string]) {.async.} =
  for topic in topics:
    trace "sending graft msg to peer", peer = p.id, topicID = topic
    await p.send(@[RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))])

proc sendPrune*(p: PubSubPeer, topics: seq[string]) {.async.} =
  for topic in topics:
    trace "sending prune msg to peer", peer = p.id, topicID = topic
    await p.send(@[RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))])

proc newPubSubPeer*(peerInfo: PeerInfo,
                    proto: string): PubSubPeer =
  new result
  result.proto = proto
  result.peerInfo = peerInfo
  result.sentRpcCache = newTimedCache[string](2.minutes)
  result.recvdRpcCache = newTimedCache[string](2.minutes)
  result.onConnect = newAsyncEvent()
