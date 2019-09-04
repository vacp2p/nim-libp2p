## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../../stream/bufferstream
import types

type
  Channel* = ref object of BufferStream
    id*: int
    initiator*: bool
    isReset*: bool
    closedLocal*: bool
    closedRemote*: bool
    handlerFuture*: Future[void]

proc newChannel*(id: int,
                 initiator: bool,
                 handler: WriteHandler,
                 size: int = MaxMsgSize): Channel = 
  new result
  result.id = id
  result.initiator = initiator
  result.initBufferStream(handler, size)

proc closed*(s: Channel): bool = s.closedLocal and s.closedRemote
proc close*(s: Channel) {.async.} = discard
proc reset*(s: Channel) {.async.} = discard
