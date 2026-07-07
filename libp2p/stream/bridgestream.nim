# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import pkg/chronos
import connection, bufferstream

export connection

type
  WriteHandler = proc(data: sink seq[byte]): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  BridgeStream* = ref object of BufferStream
    writeHandler: WriteHandler
    closeHandler: proc(): Future[void] {.async: (raises: []).}
    writeLock: AsyncLock

method write*(
    s: BridgeStream, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  await s.writeLock.acquire()
  try:
    await s.writeHandler(move(msg))
  finally:
    try:
      s.writeLock.release()
    except AsyncLockError as exc:
      raiseAssert "BridgeStream write lock release failed: " & exc.msg

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
  connA.writeLock = newAsyncLock()
  connB.writeLock = newAsyncLock()
  connA.initStream()
  connB.initStream()

  connA.writeHandler = proc(
      data: sink seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connB.pushData(move(data))
  connB.writeHandler = proc(
      data: sink seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connA.pushData(move(data))

  if closeTogether:
    connA.closeHandler = proc(): Future[void] {.async: (raises: []).} =
      await noCancel connB.close()
    connB.closeHandler = proc(): Future[void] {.async: (raises: []).} =
      await noCancel connA.close()

  return (connA, connB)
