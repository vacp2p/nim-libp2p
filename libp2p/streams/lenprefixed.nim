## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles, stew/byteutils
import ringbuffer,
       stream,
       utils,
      ../varint,
      ../vbuffer

logScope:
  topic = "LenPrefixed"

const
  DefaultBuffSize* = 1 shl 20
  SafeVarintSize* = sizeof(uint)

type
  InvalidVarintException* = object of CatchableError
  InvalidVarintSizeException* = object of CatchableError

  LenPrefixed* = ref object
    readBuff: RingBuffer[byte]
    buff: seq[byte]
    pos, size: int
    mode: Mode

  Mode {.pure.} = enum Decoding, Reading

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "Unable to parse varint")

proc newInvalidVarintSizeException*(): ref InvalidVarintSizeException =
  newException(InvalidVarintSizeException, "Wrong varint size")

proc decodeLen(lp: LenPrefixed): int =
  var
    size: uint
    length: int
    res: VarintStatus
  for i in 0..SafeVarintSize:
    lp.buff[i] = lp.readBuff.read(1)[0]
    res = LP.getUVarint(lp.buff.toOpenArray(0, i), length, size)

    if res == VarintStatus.Success:
      break

  if length > SafeVarintSize:
    raise newInvalidVarintSizeException()

  return size.int

proc read(lp: LenPrefixed,
          chunk: Future[seq[byte]]):
          Future[seq[byte]] {.async, gcsafe.} =
  try:
      var cchunk = await chunk
      if cchunk.len <= 0:
        return

      lp.readBuff.append((await chunk))

      while lp.readBuff.len > 0:
        case lp.mode:
        of Mode.Decoding:
          lp.size = lp.decodeLen()
          if lp.size <= 0:
            raise newInvalidVarintException()

          lp.mode = Mode.Reading
        else:
          var last = lp.pos + lp.size - 1
          if last <= 0:
            last = 1

          var read = lp.readBuff.read(lp.buff.toOpenArray(lp.pos, last))
          lp.size -= read
          lp.pos += read

          if lp.size <= 0:
            lp.mode = Mode.Decoding
            result = lp.buff[0..<lp.pos]
            lp.pos = 0
            return

  except CatchableError as exc:
    trace "Exception occured", exc = exc.msg
    raise exc

proc decoder*(lp: LenPrefixed): Through[seq[byte]] =
  return proc(i: Source[seq[byte]]): Source[seq[byte]] =
    return iterator(abort: bool = false): Future[seq[byte]] {.closure.} =
      for chunk in i(abort):
        while true:
          yield lp.read(chunk)
          if lp.readBuff.len <= 0:
            break

      trace "source ended, clenaning up"

proc write(lp: LenPrefixed,
           chunk: Future[seq[byte]]):
           Future[seq[byte]] {.async.} =
  var buf = initVBuffer()
  var msg = await chunk
  if msg.len <= 0:
    return

  buf.writeSeq(msg)
  result = buf.buffer

proc encoder*(lp: LenPrefixed): Through[seq[byte]] =
  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(abort: bool = false): Future[seq[byte]] {.closure.} =
      for chunk in i(abort):
        yield lp.write(chunk)

      trace "source ended, clenaning up"

proc rest*(lp: LenPrefixed): Source[seq[byte]] =
  return iterator(abort: bool = false): Future[seq[byte]] =
    if lp.readBuff.len > 0 and not abort:
      yield lp.readBuff.read().toFuture

proc init*(lp: type[LenPrefixed], maxSize: int = DefaultBuffSize): lp =
  LenPrefixed(readBuff: RingBuffer[byte].init(maxSize),
              buff: newSeq[byte](maxSize), # TODO: don't allocate all - grow dinamicaly
              mode: Mode.Decoding,
              pos: 0, size: 0)

when isMainModule:
  import unittest, sequtils, strutils
  import writable, utils

  suite "Lenght Prefixed":
    test "encode":
      proc test() {.async.} =
        var writable = ByteWritable.init()
        var lp = LenPrefixed.init()

        var source = pipe(writable, lp.encoder())
        await writable.write(cast[seq[byte]]("HELLO"))
        check: (await source()) == @[5, 72, 69, 76, 76, 79].mapIt( it.byte )

      waitFor(test())

    test "encode multiple":
      proc test() {.async.} =
        var writable = ByteWritable.init()
        var lp = LenPrefixed.init()
        var source = pipe(writable, lp.encoder())

        proc read(): Future[bool] {.async.} =
          var count = 6
          for chunk in source:
            var msg = await chunk
            if msg.len <= 0:
              break

            check:
              msg.len == count
            count.inc

          return true

        var reader = read()
        for i in 5..<15:
          var msg = toSeq("a".repeat(i)).mapIt( it.byte )
          await writable.write(msg)
        await writable.close()

        check: await reader

      waitFor(test())

    test "decode":
      proc test() {.async.} =
        var writable = ByteWritable.init(eofTag = @[])
        var lp = LenPrefixed.init()

        var source = pipe(writable, lp.decoder())
        await writable.write(@[5, 72, 69, 76, 76, 79].mapIt( it.byte ))
        check: (await source()) == @[72, 69, 76, 76, 79].mapIt( it.byte )
        await writable.close()

      waitFor(test())

    test "decode in parts":
      proc test() {.async.} =
        var writable = ByteWritable.init(eofTag = @[])
        var lp = LenPrefixed.init()

        proc write() {.async.} =
          await writable.write(@[5, 72, 69].mapIt( it.byte ))
          await writable.write(@[76, 76, 79].mapIt( it.byte ))
          await writable.close()

        var source = pipe(writable, lp.decoder())
        var writer = write()

        var res: seq[byte]
        for i in source:
          res &= await i

        check:
          res == @[72, 69, 76, 76, 79].mapIt( it.byte )

        await writer

      waitFor(test())
