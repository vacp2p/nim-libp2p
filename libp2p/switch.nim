## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import connection, transport, stream, peerinfo, multiaddress

type
  ProtoHandler* = proc (conn: Connection, proto: string): Future[void]
  ProtoHolder* = object of RootObj
    proto: string
    handler: ProtoHandler

  Switch* = ref object of RootObj
    connections*: seq[Connection]
    transport*: seq[Transport]
    peerInfo*: PeerInfo
    protos: seq[ProtoHolder]

proc newSwitch*(): Switch =
  new result

proc dial*(peer: PeerInfo, proto: string = "") {.async.} = discard
proc mount*(proto: string, handler: ProtoHandler) {.async.} = discard

proc start*() {.async.} = discard
proc stop*() {.async.} = discard
