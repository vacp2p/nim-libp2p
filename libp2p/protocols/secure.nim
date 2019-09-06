## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import protocol
import ../connection

const PlainTextCodec* = "/plaintext/1.0.0"

type
  Secure* = ref object of LPProtocol # base type for secure managers

  PlainText* = ref object of Secure

method init(p: PlainText) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} = discard
    ## plain text doesn't do anything

  p.codec = PlainTextCodec
  p.handler = handle

proc newPlainText*(): PlainText =
  new result
  result.init()
