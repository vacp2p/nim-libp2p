# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## `Perf <https://github.com/libp2p/specs/blob/master/perf/perf.md>`_ protocol specification

{.push raises: [].}

import chronos, chronicles
import stew/endians2
import ./core, ../protocol, ../../stream/connection, ../../utility

export chronicles, connection

logScope:
  topics = "libp2p perf"

type Perf* = ref object of LPProtocol

proc new*(T: typedesc[Perf]): T {.public.} =
  var p = T()

  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      trace "Received benchmark performance check", conn

      var uploadSizeBuffer: array[8, byte]
      await conn.readExactly(addr uploadSizeBuffer[0], 8)
      var uploadSize = uint64.fromBytesBE(uploadSizeBuffer)

      var readBuffer: array[PerfSize, byte]
      while not conn.atEof:
        try:
          let readBytes = await conn.readOnce(addr readBuffer[0], PerfSize)
          if readBytes == 0:
            break
        except LPStreamEOFError:
          break

      var writeBuffer: array[PerfSize, byte]
      while uploadSize > 0:
        let toWrite = min(uploadSize, PerfSize)
        await conn.write(writeBuffer[0 ..< toWrite])
        uploadSize -= toWrite
    except CancelledError as exc:
      trace "cancelled perf handler"
      raise exc
    except CatchableError as exc:
      trace "exception in perf handler", description = exc.msg, conn
    finally:
      await conn.close()

  p.handler = handle
  p.codec = PerfCodec
  return p
