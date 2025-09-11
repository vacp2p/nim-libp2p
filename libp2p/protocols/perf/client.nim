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
when defined(libp2p_quic_support):
  import ../../transports/quictransport

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
  return p.stats

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

    # Close connection after writing for TCP, but not for QUIC
    when defined(libp2p_quic_support):
      if not (conn of QuicStream):
        await conn.close()
      # For QUIC streams, don't close yet - let server manage lifecycle
    else:
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

    # Close QUIC connections after read phase
    when defined(libp2p_quic_support):
      if conn of QuicStream:
        await conn.close()
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    raise e
  finally:
    p.stats.isFinal = true

  trace "finishing performance benchmark", duration = p.stats.duration

  return p.stats.duration
