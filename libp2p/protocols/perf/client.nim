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
  stats: Stats

proc new*(T: typedesc[PerfClient]): T =
  return T()

proc currentStats*(p: PerfClient): Stats =
  p.stats

proc perf*(
    p: PerfClient, conn: Connection, sizeToWrite: uint64 = 0, sizeToRead: uint64 = 0
): Future[Duration] {.public, async: (raises: [CancelledError, LPStreamError]).} =
  trace "starting performance benchmark", conn, sizeToWrite, sizeToRead

  p.stats = Stats()

  try:
    var
      size = sizeToWrite
      buf: array[PerfSize, byte]

    let start = Moment.now()

    await conn.write(toSeq(toBytesBE(sizeToRead)))
    while size > 0:
      let toWrite = min(size, PerfSize)
      await conn.write(buf[0 ..< toWrite])
      size -= toWrite.uint

      # set stats using copy value to avoid race condition
      var statsCopy = p.stats
      statsCopy.duration = Moment.now() - start
      statsCopy.uploadBytes += toWrite.uint
      p.stats = statsCopy

    await conn.close()

    size = sizeToRead

    while size > 0:
      let toRead = min(size, PerfSize)
      await conn.readExactly(addr buf[0], toRead.int)
      size = size - toRead.uint

      # set stats using copy value to avoid race condition
      var statsCopy = p.stats
      statsCopy.duration = Moment.now() - start
      statsCopy.downloadBytes += toRead.uint
      p.stats = statsCopy
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    raise e
  finally:
    p.stats.isFinal = true

  trace "finishing performance benchmark", duration = p.stats.duration

  return p.stats.duration
