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

type PerfClient* = ref object of RootObj

proc perf*(
    _: typedesc[PerfClient],
    conn: Connection,
    sizeToWrite: uint64 = 0,
    sizeToRead: uint64 = 0,
): Future[Duration] {.async, public.} =
  var
    size = sizeToWrite
    buf: array[PerfSize, byte]
  let start = Moment.now()
  trace "starting performance benchmark", conn, sizeToWrite, sizeToRead

  await conn.write(toSeq(toBytesBE(sizeToRead)))
  while size > 0:
    let toWrite = min(size, PerfSize)
    await conn.write(buf[0 ..< toWrite])
    size -= toWrite

  await conn.close()

  size = sizeToRead

  while size > 0:
    let toRead = min(size, PerfSize)
    await conn.readExactly(addr buf[0], toRead.int)
    size = size - toRead

  let duration = Moment.now() - start
  trace "finishing performance benchmark", duration
  return duration
