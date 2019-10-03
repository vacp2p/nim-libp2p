## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, sets, hashes, strutils
import chronos, chronicles
import rpcmsg, 
       timedcache,
       ../../peer,
       ../../peerinfo,
       ../../connection,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf

logScope:
  topic = "PubSubPeer"

type
    PubSubPeer* = ref object of RootObj
      id*: string # base58 peer id string
      peerInfo*: PeerInfo
      conn*: Connection
      handler*: RPCHandler
      topics*: seq[string]
      seen: TimedCache[string] # list of messages forwarded to peers

    RPCHandler* = proc(peer: PubSubPeer, msg: seq[RPCMsg]): Future[void] {.gcsafe.}

proc handle*(p: PubSubPeer) {.async, gcsafe.} =
  trace "handling pubsub rpc", peer = p.id
  try:
    while not p.conn.closed:
      let data = await p.conn.readLp()
      trace "Read data from peer", peer = p.id, data = data.toHex()
      if data.toHex() in p.seen:
        trace "Message already received, skipping", peer = p.id
        continue

      let msg = decodeRpcMsg(data)
      trace "Decoded msg from peer", peer = p.id, msg = msg
      await p.handler(p, @[msg])
  except:
    error "An exception occured while processing pubsub rpc requests", exc = getCurrentExceptionMsg()
  finally:
    trace "closing connection to pubsub peer", peer = p.id
    await p.conn.close()

proc send*(p: PubSubPeer, msgs: seq[RPCMsg]) {.async, gcsafe.} =
  for m in msgs:
    trace "sending msgs to peer", peer = p.id, msgs = msgs
    let encoded = encodeRpcMsg(m)
    if encoded.buffer.len <= 0:
      trace "empty message, skipping", peer = p.id
      return

    let encodedHex = encoded.buffer.toHex()
    if encodedHex in p.seen:
      trace "message already sent to peer, skipping", peer = p.id
      continue

    trace "sending encoded msgs to peer", peer = p.id, encoded = encodedHex
    await p.conn.writeLp(encoded.buffer)
    p.seen.put(encodedHex)

proc newPubSubPeer*(conn: Connection, handler: RPCHandler): PubSubPeer =
  new result
  result.handler = handler
  result.conn = conn
  result.peerInfo = conn.peerInfo
  result.id = conn.peerInfo.peerId.get().pretty()
  result.seen = newTimedCache[string]()
