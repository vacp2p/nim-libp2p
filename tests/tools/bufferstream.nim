# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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
