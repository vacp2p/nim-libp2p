## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import ringbuffer,
       stream,
      ../varint,
      ../vbuffer

const
  DefaultBuffSize* = 4 shl 20
  SafeVarintSize* = 4

type
  InvalidVarintException* = object of CatchableError
  InvalidVarintSizeException* = object of CatchableError

  LenPrefixed* = ref object {.requiresInit.}
    readBuff: RingBuffer[byte]
    buff: seq[byte]
    pos, size: int
    mode: Mode

  Mode {.pure.} = enum Decoding, Reading

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "Unable to parse varint")

proc newInvalidVarintSizeException*(): ref InvalidVarintSizeException =
  newException(InvalidVarintSizeException, "Wrong varint size")

proc init*(lp: type[LenPrefixed], maxSize: int = DefaultBuffSize): lp =
  LenPrefixed(readBuff: RingBuffer[byte].init(maxSize),
              buff: newSeq[byte](maxSize),
              mode: Mode.Decoding,
              pos: 0, size: 0)

proc decodeLen(lp: LenPrefixed): int =
  var
    size: uint
    length: int
    res: VarintStatus
    buff: seq[byte]
    i: int
  while true:
    buff.add(lp.readBuff.read(1))
    res = LP.getUVarint(buff, length, size)
    i.inc

    if res == VarintStatus.Success:
      break

    if buff.len > SafeVarintSize:
      raise newInvalidVarintSizeException()

  return size.int

proc read(lp: LenPrefixed,
          i: Source[seq[byte]]):
          Future[seq[byte]] {.async, gcsafe.} =
  try:
    for chunk in i:
      lp.readBuff.append((await chunk))

      while lp.readBuff.len > 0:
        case lp.mode:
        of Mode.Decoding:
          lp.size = lp.decodeLen()
          lp.mode = Mode.Reading
        else:
          var read = 0
          read += lp.readBuff.read(lp.buff.toOpenArray(lp.pos, lp.pos + lp.size))
          lp.size -= read
          lp.pos += read
          if lp.size == 0:
            lp.mode = Mode.Decoding
            result = lp.buff[0..<lp.pos]
            echo result
            echo cast[string](result)
            lp.pos = 0
            break

  except CatchableError as exc:
    trace "Exception occured", exc = exc.msg
    raise exc

proc decoder*(lp: LenPrefixed): Through[seq[byte]] =
  return proc(i: Source[seq[byte]]): Source[seq[byte]] =
    return iterator(): Future[seq[byte]] {.closure.} =
      yield lp.read(i)
      echo "EXITING LEN"

proc write(lp: LenPrefixed,
           chunk: Future[seq[byte]]):
           Future[seq[byte]] {.async.} =
  var buf = initVBuffer()
  buf.writeSeq((await chunk))
  result = buf.buffer

proc encoder*(lp: LenPrefixed): Through[seq[byte]] =
  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(): Future[seq[byte]] {.closure.} =
      for chunk in i:
        yield lp.write(chunk)

when isMainModule:
  import unittest, sequtils, strutils
  import pushable

  suite "Lenght Prefixed":
    test "encode":
      proc test(): Future[bool] {.async.} =
        var pushable = Pushable[seq[byte]].init()
        var lp = LenPrefixed.init()

        var source = pipe(pushable, lp.encoder())
        await pushable.push(cast[seq[byte]]("HELLO"))
        result = (await source()) == @[5, 72, 69, 76, 76, 79].mapIt( it.byte )

      check:
        waitFor(test()) == true

    test "encode multiple":
      proc test(): Future[bool] {.async.} =
        var pushable = Pushable[seq[byte]].init()
        var lp = LenPrefixed.init()

        var source = pipe(pushable, lp.encoder())

        proc read(): Future[bool] {.async.} =
          var count = 6
          for chunk in source:
            check:
              (await chunk).len == count
            count.inc
          result = true

        var reader = read()
        for i in 5..<15:
          await pushable.push(toSeq("a".repeat(i)).mapIt( it.byte ))
        await pushable.close()

        result = await reader

      check:
        waitFor(test()) == true

    test "decode":
      proc test(): Future[bool] {.async.} =
        var pushable = Pushable[seq[byte]].init()
        var lp = LenPrefixed.init()

        var source = pipe(pushable, lp.decoder())
        await pushable.push(@[5, 72, 69, 76, 76, 79].mapIt( it.byte ))
        await pushable.close()

        result = (await source()) == @[72, 69, 76, 76, 79].mapIt( it.byte )

      check:
        waitFor(test()) == true

    test "decode in parts":
      proc test(): Future[bool] {.async.} =
        var pushable = Pushable[seq[byte]].init()
        var lp = LenPrefixed.init()

        proc write() {.async.} =
          await pushable.push(@[5, 72, 69].mapIt( it.byte ))
          await pushable.push(@[76, 76, 79].mapIt( it.byte ))
          await pushable.close()

        var source = pipe(pushable, lp.decoder())
        var writer = write()

        var res: seq[byte]
        for i in source:
          res &= await i

        result = res == @[72, 69, 76, 76, 79].mapIt( it.byte )
        await writer
      check:
        waitFor(test()) == true
