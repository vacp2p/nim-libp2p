## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos, chronicles
import ../../connection,
       ../../protobuf/minprotobuf,
       ../../peerinfo,
       rpcmsg

logScope:
  topic = "PubSubPeer"

type
    PubSubPeer* = ref object of RootObj
      conn*: Connection
      handler*: RPCHandler
      topics*: seq[string]

    RPCHandler* = proc(peer: PubSubPeer, msg: seq[RPCMsg]): Future[void] {.gcsafe.}

proc handle*(p: PubSubPeer) {.async, gcsafe.} =
  try:
    while not p.conn.closed:
      let msg = decodeRpcMsg(await p.conn.readLp())
      await p.handler(p, @[msg])
  except:
    debug "An exception occured while processing pubsub rpc requests", exc = getCurrentExceptionMsg()
    return
  finally:
    await p.conn.close()

proc send*(p: PubSubPeer, msgs: seq[RPCMsg]) {.async, gcsafe.} =
  for m in msgs:
    await p.conn.writeLp(encodeRpcMsg(m).buffer)

proc newPubSubPeer*(conn: Connection, handler: RPCHandler): PubSubPeer =
  new result
  result.handler = handler
  result.conn = conn
