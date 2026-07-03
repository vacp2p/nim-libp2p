# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `Perf <https://github.com/libp2p/specs/blob/master/perf/perf.md>`_ protocol specification

{.push raises: [].}

import chronos, chronicles
import stew/endians2
import ./core, ../protocol, ../../stream/connection

export chronicles, connection

logScope:
  topics = "libp2p perf"

type Perf* = ref object of LPProtocol

proc new*(T: typedesc[Perf]): T =
  var p = T()

  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      trace "Received benchmark performance check", stream

      var uploadSizeBuffer: array[8, byte]
      await stream.readExactly(addr uploadSizeBuffer[0], 8)
      var uploadSize = uint64.fromBytesBE(uploadSizeBuffer)

      var readBuffer: array[PerfSize, byte]
      while not stream.atEof:
        try:
          let readBytes = await stream.readOnce(addr readBuffer[0], PerfSize)
          if readBytes == 0:
            break
        except LPStreamEOFError:
          break

      var writeBuffer: array[PerfSize, byte]
      while uploadSize > 0:
        let toWrite = min(uploadSize, PerfSize)
        await stream.write(writeBuffer[0 ..< toWrite])
        uploadSize -= toWrite
    except CancelledError as exc:
      trace "cancelled perf handler"
      raise exc
    except CatchableError as exc:
      trace "exception in perf handler", description = exc.msg, stream
    finally:
      await stream.close()

  p.handler = handle
  p.codec = PerfCodec
  return p
