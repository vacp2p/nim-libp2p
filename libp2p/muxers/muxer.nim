## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../protocol, ../connection

type
  Muxer* = ref object of RootObj
    connection*: Connection

  MuxerCreator* = proc(conn: Connection): Muxer {.gcsafe, closure.}
  # this wraps a creator proc that knows how to make muxers
  MuxerProvider* = ref object of LPProtocol
    newMuxer*: MuxerCreator

proc newMuxerProvider*(creator: MuxerCreator, codec: string): MuxerProvider {.gcsafe.} = 
  new result
  result.newMuxer = creator
  result.codec = codec
  
method init(c: MuxerProvider) =
  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let muxer = c.newMuxer(conn)

  c.handler = handler

method newStream*(m: Muxer): Future[Connection] {.base, async, gcsafe.} = discard
method close*(m: Muxer) {.base, async, gcsafe.} = discard
method handle*(m: Muxer): Future[void] {.base, async, gcsafe.} = discard
