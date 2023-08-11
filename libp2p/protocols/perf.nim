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

import chronos, chronicles, sequtils
import stew/endians2
import ../protobuf/minprotobuf,
       ../peerinfo,
       ../stream/connection,
       ../peerid,
       ../crypto/crypto,
       ../multiaddress,
       ../protocols/protocol,
       ../utility,
       ../errors

export chronicles, rand, connection

logScope:
  topics = "libp2p perf"

const
  PerfCodec* = "/perf/1.0.0"
  PerfSize = 65536

type
  PerfError* = object of LPError

  Perf* = ref object of LPProtocol

proc new*(T: typedesc[Perf]): T {.public.} =
  var p = T()
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var bytesRead = 0
    try:
      trace "Received benchmark performance check", conn
      var
        sizeBuffer: array[8, byte]
        size: uint64
      await conn.readExactly(addr sizeBuffer[0], 8)
      size = uint64.fromBytesBE(sizeBuffer)

      var toReadBuffer: array[PerfSize, byte]
      try:
        while true:
          bytesRead += await conn.readOnce(addr toReadBuffer[0], PerfSize)
      except CatchableError as exc:
        discard

      var buf: array[PerfSize, byte]
      while size > 0:
        let toWrite = min(size, PerfSize)
        await conn.write(buf[0..<toWrite])
        size -= toWrite
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in perf handler", exc = exc.msg, conn
    await conn.close()

  p.handler = handle
  p.codec = PerfCodec
  return p

proc perf*(conn: Connection, sizeToWrite: uint64 = 0, sizeToRead: uint64 = 0):
           Future[Duration] {.async, public.} =
  var
    size = sizeToWrite
    buf: array[PerfSize, byte]
  let start = Moment.now()
  trace "starting performance benchmark", conn, sizeToWrite, sizeToRead

  await conn.write(toSeq(toBytesBE(sizeToRead)))
  while size > 0:
    let toWrite = min(size, PerfSize)
    await conn.write(buf[0..<toWrite])
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

proc perfDownload*(conn: Connection, sizeToRead: uint64):
                   Future[Duration] {.async, public.} =
  return await conn.perf(sizeToRead = sizeToRead)

proc perfUpload*(conn: Connection, sizeToWrite: uint64):
                 Future[Duration] {.async, public.} =
  return await conn.perf(sizeToWrite = sizeToWrite)
