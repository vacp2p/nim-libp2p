# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import pkg/chronos
import connection, bufferstream

export connection

type
  WriteHandler = proc(data: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  BridgeStream* = ref object of BufferStream
    writeHandler: WriteHandler
    closeHandler: proc(): Future[void] {.async: (raises: []).}

method write*(
    s: BridgeStream, msg: seq[byte]
): Future[void] {.public, async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writeHandler(msg)

method closeImpl*(s: BridgeStream): Future[void] {.async: (raises: [], raw: true).} =
  if not isNil(s.closeHandler):
    discard s.closeHandler()

  procCall BufferStream(s).closeImpl()

method getWrapped*(s: BridgeStream): Connection =
  nil

proc bridgedConnections*(
    closeTogether: bool = true, dirA = Direction.In, dirB = Direction.In
): (BridgeStream, BridgeStream) =
  let connA = BridgeStream()
  let connB = BridgeStream()
  connA.dir = dirA
  connB.dir = dirB
  connA.initStream()
  connB.initStream()

  connA.writeHandler = proc(
      data: seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connB.pushData(data)
  connB.writeHandler = proc(
      data: seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connA.pushData(data)

  if closeTogether:
    connA.closeHandler = proc(): Future[void] {.async: (raises: []).} =
      await noCancel connB.close()
    connB.closeHandler = proc(): Future[void] {.async: (raises: []).} =
      await noCancel connA.close()

  return (connA, connB)
