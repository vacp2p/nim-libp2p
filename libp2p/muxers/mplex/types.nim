## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../../connection

const MaxMsgSize* = 1 shl 20 # 1mb
const MaxChannels* = 1000
const MplexCodec* = "/mplex/6.7.0"

type
  MplexUnknownMsgError* = object of CatchableError
  MessageType* {.pure.} = enum
    New,
    MsgIn,
    MsgOut,
    CloseIn,
    CloseOut,
    ResetIn,
    ResetOut

  StreamHandler* = proc(conn: Connection): Future[void] {.gcsafe.}
