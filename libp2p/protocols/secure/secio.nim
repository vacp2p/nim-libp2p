## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import secure,
       ../../connection

const SecioCodec* = "/plaintext/1.0.0"

type
  Secio = ref object of Secure

proc encodeProposalMsg*() = discard
proc decodeProposalMsg*() = discard

method init(p: Secio) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} = 
    discard

  p.codec = SecioCodec
  p.handler = handle

proc newSecio*(): Secio =
  new result
  result.init()

