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
    var bytesRead = 0
    try:
      trace "Received benchmark performance check", conn
      var
        sizeBuffer: array[8, byte]
        size: uint64
      await conn.readExactly(addr sizeBuffer[0], 8)
      size = uint64.fromBytesBE(sizeBuffer)

      var toReadBuffer: array[PerfSize, byte]
      # Read client data until EOF (when client closes write side)
      trace "Server: Starting to read client data"
      while true:
        try:
          let read = await conn.readOnce(addr toReadBuffer[0], PerfSize)
          if read == 0:
            trace "Server: EOF reached, bytesRead", bytesRead
            break  # EOF reached
          bytesRead += read
          trace "Server: Read bytes", read, totalBytesRead = bytesRead
        except CatchableError as exc:
          trace "Server: Exception while reading", exc = exc.msg
          break  # Connection error or EOF

      var buf: array[PerfSize, byte]
      while size > 0:
        let toWrite = min(size, PerfSize)
        await conn.write(buf[0 ..< toWrite])
        size -= toWrite
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
