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
      ../varint,
      ../vbuffer

const
  DefaultBuffSize* = 1024
  SafeVarintSize* = 4

type
  LenPrefixed* = ref object
    readBuff: RingBuffer[byte]
    writeBuff: RingBuffer[byte]
    mode: Mode
    size: int

  Mode {.pure.} = enum Decoding, Reading

  InvalidVarintException* = object of CatchableError
  InvalidVarintSizeException* = object of CatchableError

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "Unable to parse varint")

proc newInvalidVarintSizeException*(): ref InvalidVarintSizeException =
  newException(InvalidVarintSizeException, "Wrong varint size")

proc init*(lp: type[LenPrefixed], maxSize: int = DefaultBuffSize): lp =
  LenPrefixed(readBuff: RingBuffer[byte].init(maxSize),
              writeBuff: RingBuffer[byte].init(maxSize),
              mode: Mode.Decoding)

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
          chunk: Future[seq[byte]]):
          Future[seq[byte]] {.async, gcsafe.} =
  try:
    lp.readBuff.append((await chunk))

    while lp.readBuff.len > 0:
      case lp.mode:
      of Mode.Decoding:
        lp.size = lp.decodeLen()
        lp.mode = Mode.Reading
      else:
        result = lp.readBuff.read(lp.size)
        echo result
        lp.size -= result.len
        if lp.size == 0:
          lp.mode = Mode.Decoding

  except CatchableError as exc:
    trace "Exception occured", exc = exc.msg
    raise exc

proc decode*(lp: LenPrefixed,
             i: iterator(): Future[seq[byte]]):
             iterator(): Future[seq[byte]] =
  return iterator(): Future[seq[byte]] =
    for chunk in i():
      yield lp.read(chunk)

proc write(lp: LenPrefixed,
           i: iterator(): Future[seq[byte]]):
           Future[seq[byte]] {.async.} =
  for chunk in i():
    lp.writeBuff.append((await chunk))

  var buf = initVBuffer()
  buf.writeSeq(lp.writeBuff.read())
  buf.finish()
  result = buf.buffer

proc encode*(lp: LenPrefixed,
             i: iterator(): Future[seq[byte]]):
             iterator(): Future[seq[byte]] =
  return iterator(): Future[seq[byte]] =
    yield lp.write(i)
