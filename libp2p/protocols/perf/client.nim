# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## `Perf <https://github.com/libp2p/specs/blob/master/perf/perf.md>`_ protocol specification

import chronos, chronicles, sequtils
import stew/endians2
import ./core, ../../stream/connection

logScope:
  topics = "libp2p perf"

type Stats* = object
  isFinal*: bool
  uploadBytes*: uint
  downloadBytes*: uint
  duration*: Duration

type PerfClient* = ref object
  stats*: Stats

proc new*(T: typedesc[PerfClient]): T =
  return T()

proc perf*(
    p: PerfClient, conn: Connection, sizeToWrite: uint64 = 0, sizeToRead: uint64 = 0
): Future[Duration] {.public, async: (raises: [CancelledError, LPStreamError]).} =
  trace "starting performance benchmark", conn, sizeToWrite, sizeToRead

  var
    size = sizeToWrite
    buf: array[PerfSize, byte]

  p.stats = Stats()
  let start = Moment.now()

  await conn.write(toSeq(toBytesBE(sizeToRead)))
  while size > 0:
    let toWrite = min(size, PerfSize)
    await conn.write(buf[0 ..< toWrite])
    size -= toWrite
    p.stats.duration = Moment.now() - start
    p.stats.uploadBytes += toWrite

  await conn.close()

  size = sizeToRead

  while size > 0:
    let toRead = min(size, PerfSize)
    await conn.readExactly(addr buf[0], toRead.int)
    size = size - toRead
    p.stats.duration = Moment.now() - start
    p.stats.downloadBytes += toRead

  p.stats.isFinal = true

  let duration = Moment.now() - start
  trace "finishing performance benchmark", duration
  return duration
