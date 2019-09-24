## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos, chronicles
import rpcmsg,
       ../../peer,
       ../../peerinfo,
       ../../connection,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf

logScope:
  topic = "PubSubPeer"

type
    PubSubPeer* = ref object of RootObj
      peerInfo*: PeerInfo
      conn*: Connection
      handler*: RPCHandler
      topics*: seq[string]
      id*: string # base58 peer id string

    RPCHandler* = proc(peer: PubSubPeer, msg: seq[RPCMsg]): Future[void] {.gcsafe.}

proc handle*(p: PubSubPeer) {.async, gcsafe.} =
  trace "handling pubsub rpc", peer = p.id
  try:
    while not p.conn.closed:
      let data = await p.conn.readLp()
      trace "Read data from peer", peer = p.peerInfo, data = data.toHex()
      let msg = decodeRpcMsg(data)
      trace "Decoded msg from peer", peer = p.peerInfo, msg = msg
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
    if encoded.buffer.len > 0:
      await p.conn.writeLp(encoded.buffer)

proc newPubSubPeer*(conn: Connection, handler: RPCHandler): PubSubPeer =
  new result
  result.handler = handler
  result.conn = conn
  result.peerInfo = conn.peerInfo
  result.id = conn.peerInfo.peerId.get().pretty()
