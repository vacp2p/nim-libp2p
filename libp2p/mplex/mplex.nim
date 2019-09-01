## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables
import chronos
import ../connection, ../stream
import types
import channel

type
  ChannelHandler* = proc(conn: Connection) {.gcsafe.}

  Mplex* = ref object of RootObj
    connections*: seq[Connection]
    channels*: TableRef[uint, Connection]
    handler*: ChannelHandler

proc newMplex*(handler: ChannelHandler): Mplex =
  new result
  result.channels = newTable[uint, Connection]()
  result.handler = handler

proc newStream*(m: Mplex, conn: Connection): Connection {.gcsafe.} = discard
proc handle*(m: Mplex, conn: Connection) {.gcsafe.} = discard
proc send*(m: Mplex, msg: Message) {.async, gcsafe.} = discard
