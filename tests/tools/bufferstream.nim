# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../../libp2p/stream/[chronosstream, bufferstream, lpstream]

type
  WriteHandler* = proc(data: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  TestBufferStream* = ref object of BufferStream
    writeHandler*: WriteHandler

method write*(
    s: TestBufferStream, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writeHandler(msg)

method getWrapped*(s: TestBufferStream): Connection =
  nil

proc new*(T: typedesc[TestBufferStream], writeHandler: WriteHandler): T =
  let testBufferStream = T(writeHandler: writeHandler)
  testBufferStream.initStream()
  testBufferStream
