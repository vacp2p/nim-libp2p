## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, hashes, strutils, sequtils, tables
import chronos, chronicles
import rpc/[messages, message, protobuf], 
       timedcache,
       ../../peer,
       ../../peerinfo,
       ../../connection,
       ../../stream/lpstream,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf

logScope:
  topic = "PubSubPeer"

type
    PubSubPeer* = ref object of RootObj
      id*: string # base58 peer id string
      proto: string # the protocol that this peer joined from
      peerInfo*: PeerInfo
      conn*: Connection
      handler*: RPCHandler
      topics*: seq[string]
      sentRpcCache: TimedCache[string] # a cache of already sent messages
      recvdRpcCache: TimedCache[string] # a cache of already sent messages

    RPCHandler* = proc(peer: PubSubPeer, msg: seq[RPCMsg]): Future[void] {.gcsafe.}

proc handle*(p: PubSubPeer) {.async, gcsafe.} =
  trace "handling pubsub rpc", peer = p.id
  try:
    while not p.conn.closed:
      let data = await p.conn.readLp()
      let hexData = data.toHex()
      trace "read data from peer", peer = p.id, data = hexData
      if hexData in p.recvdRpcCache:
        trace "message already received, skipping", peer = p.id
        continue

      let msg = decodeRpcMsg(data)
      trace "decoded msg from peer", peer = p.id, msg = msg
      await p.handler(p, @[msg])
      p.recvdRpcCache.put(hexData)
  except:
    error "an exception occured while processing pubsub rpc requests", exc = getCurrentExceptionMsg()
  finally:
    trace "closing connection to pubsub peer", peer = p.id
    await p.conn.close()

proc send*(p: PubSubPeer, msgs: seq[RPCMsg]) {.async, gcsafe.} =
  for m in msgs:
    trace "sending msgs to peer", toPeer = p.id, msgs = msgs
    let encoded = encodeRpcMsg(m)
    let encodedHex = encoded.buffer.toHex()
    if encoded.buffer.len <= 0:
      trace "empty message, skipping", peer = p.id
      return

    if encodedHex in p.sentRpcCache:
      trace "message already sent to peer, skipping", peer = p.id
      continue

    trace "sending encoded msgs to peer", peer = p.id, encoded = encodedHex
    await p.conn.writeLp(encoded.buffer)
    p.sentRpcCache.put(encodedHex)

proc sendMsg*(p: PubSubPeer,
              peerId: PeerID,
              topic: string,
              data: seq[byte]): Future[void] {.gcsafe.} =
  p.send(@[RPCMsg(messages: @[newMessage(p.peerInfo.peerId.get(), data, topic)])])

proc sendGraft*(p: PubSubPeer, topics: seq[string]) {.async, gcsafe.} =
  for topic in topics:
    trace "sending graft msg to peer", peer = p.id, topicID = topic
    await p.send(@[RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))])

proc sendPrune*(p: PubSubPeer, topics: seq[string]) {.async, gcsafe.} = 
  for topic in topics:
    trace "sending prune msg to peer", peer = p.id, topicID = topic
    await p.send(@[RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))])

proc newPubSubPeer*(conn: Connection, handler: RPCHandler, proto: string): PubSubPeer =
  new result
  result.handler = handler
  result.proto = proto
  result.conn = conn
  result.peerInfo = conn.peerInfo
  result.id = conn.peerInfo.peerId.get().pretty()
  result.sentRpcCache = newTimedCache[string](2.minutes)
  result.recvdRpcCache = newTimedCache[string](2.minutes)
