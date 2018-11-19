## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Google ProtoBuf's variable integer `VARINT`.
import bitops

type
  VarintStatus* = enum
    Error,
    Success,
    Overflow,
    Incomplete,
    Overrun

  SomeUVarint* = uint | uint64 | uint32
  SomeSVarint* = int | int64 | int32
  SomeVarint* = SomeUVarint | SomeSVarint
  VarintError* = object of Exception

proc vsizeof*(x: SomeUVarint|SomeSVarint): int {.inline.} =
  ## Returns number of bytes required to encode integer ``x`` as varint.
  if x == cast[type(x)](0):
    result = 1
  else:
    result = (fastLog2(x) + 1 + 7 - 1) div 7

proc getUVarint*(pbytes: openarray[byte], outlen: var int,
                 outval: var SomeUVarint): VarintStatus =
  ## Decode `unsigned varint` from buffer ``pbytes`` and store it to ``outval``.
  ## On success ``outlen`` will be set to number of bytes processed while
  ## decoding `unsigned varint`.
  ##
  ## If array ``pbytes`` is empty, ``Incomplete`` error will be returned.
  ##
  ## If there not enough bytes available in array ``pbytes`` to decode `unsigned
  ## varint`, ``Incomplete`` error will be returned.
  ##
  ## If encoded value can produce integer overflow, ``Overflow`` error will be
  ## returned.
  ##
  ## Note, when decoding 10th byte of 64bit integer only 1 bit from byte will be
  ## decoded, all other bits will be ignored. When decoding 5th byte of 32bit
  ## integer only 4 bits from byte will be decoded, all other bits will be
  ## ignored.
  const MaxBits = byte(sizeof(outval) * 8)
  var shift = 0'u8
  result = VarintStatus.Incomplete
  outlen = 0
  outval = cast[type(outval)](0)
  for i in 0..<len(pbytes):
    let b = pbytes[i]
    if shift >= MaxBits:
      result = VarintStatus.Overflow
      outlen = 0
      outval = cast[type(outval)](0)
      break
    else:
      outval = outval or (cast[type(outval)](b and 0x7F'u8) shl shift)
      shift += 7
    inc(outlen)
    if (b and 0x80'u8) == 0'u8:
      result = VarintStatus.Success
      break

  if result == VarintStatus.Incomplete:
    outlen = 0
    outval = cast[type(outval)](0)

proc putUVarint*(pbytes: var openarray[byte], outlen: var int,
                 outval: SomeUVarint): VarintStatus =
  ## Encode `unsigned varint` ``outval`` and store it to array ``pbytes``.
  ##
  ## On success ``outlen`` will hold number of bytes (octets) used to encode
  ## unsigned integer ``v``.
  ##
  ## If there not enough bytes available in buffer ``pbytes``, ``Incomplete``
  ## error will be returned and ``outlen`` will be set to number of bytes
  ## required.
  ##
  ## Maximum encoded length of 64bit integer is 10 octets.
  ## Maximum encoded length of 32bit integer is 5 octets.
  var buffer: array[10, byte]
  var value = outval
  var k = 0

  if value <= cast[type(outval)](0x7F):
    buffer[0] = cast[byte](outval and 0xFF)
    inc(k)
  else:
    while value != cast[type(outval)](0):
      buffer[k] = cast[byte]((value and 0x7F) or 0x80)
      value = value shr 7
      inc(k)
    buffer[k - 1] = buffer[k - 1] and 0x7F'u8

  outlen = k
  if len(pbytes) >= k:
    copyMem(addr pbytes[0], addr buffer[0], k)
    result = VarintStatus.Success
  else:
    result = VarintStatus.Overrun

proc getSVarint*(pbytes: openarray[byte], outsize: var int,
                 outval: var SomeSVarint): VarintStatus {.inline.} =
  ## Decode `signed varint` from buffer ``pbytes`` and store it to ``outval``.
  ## On success ``outlen`` will be set to number of bytes processed while
  ## decoding `signed varint`.
  ##
  ## If array ``pbytes`` is empty, ``Incomplete`` error will be returned.
  ##
  ## If there not enough bytes available in array ``pbytes`` to decode `signed
  ## varint`, ``Incomplete`` error will be returned.
  ##
  ## If encoded value can produce integer overflow, ``Overflow`` error will be
  ## returned.
  ##
  ## Note, when decoding 10th byte of 64bit integer only 1 bit from byte will be
  ## decoded, all other bits will be ignored. When decoding 5th byte of 32bit
  ## integer only 4 bits from byte will be decoded, all other bits will be
  ## ignored.
  when sizeof(outval) == 8:
    var value: uint64
  else:
    var value: uint32

  result = getUVarint(pbytes, outsize, value)
  if result == VarintStatus.Success:
    if (value and cast[type(value)](1)) != cast[type(value)](0):
      outval = cast[type(outval)](not(value shr 1))
    else:
      outval = cast[type(outval)](value shr 1)

proc putSVarint*(pbytes: var openarray[byte], outsize: var int,
                 outval: SomeSVarint): VarintStatus {.inline.} =
  ## Encode `signed varint` ``outval`` and store it to array ``pbytes``.
  ##
  ## On success ``outlen`` will hold number of bytes (octets) used to encode
  ## unsigned integer ``v``.
  ##
  ## If there not enough bytes available in buffer ``pbytes``, ``Incomplete``
  ## error will be returned and ``outlen`` will be set to number of bytes
  ## required.
  ##
  ## Maximum encoded length of 64bit integer is 10 octets.
  ## Maximum encoded length of 32bit integer is 5 octets.
  when sizeof(outval) == 8:
    var value: uint64 =
      if outval < 0:
        not(cast[uint64](outval) shl 1)
      else:
        cast[uint64](outval) shl 1
  else:
    var value: uint32 =
      if outval < 0:
        not(cast[uint32](outval) shl 1)
      else:
        cast[uint32](outval) shl 1
  result = putUVarint(pbytes, outsize, value)

proc encodeVarint*(value: SomeUVarint|SomeSVarint): seq[byte] {.inline.} =
  ## Encode integer to `signed/unsigned varint` and returns sequence of bytes
  ## as result.
  var outsize = 0
  result = newSeqOfCap[byte](10)
  when sizeof(value) == 4:
    result.setLen(5)
  else:
    result.setLen(10)
  when type(value) is SomeSVarint:
    let res = putSVarint(result, outsize, value)
  else:
    let res = putUVarint(result, outsize, value)
  if res == VarintStatus.Success:
    result.setLen(outsize)
  else:
    raise newException(VarintError, "Error '" & $res & "'")

proc decodeSVarint*(data: openarray[byte]): int {.inline.} =
  ## Decode signed integer from array ``data`` and return it as result.
  var outsize = 0
  let res = getSVarint(data, outsize, result)
  if res != VarintStatus.Success:
    raise newException(VarintError, "Error '" & $res & "'")

proc decodeUVarint*(data: openarray[byte]): uint {.inline.} =
  ## Decode unsigned integer from array ``data`` and return it as result.
  var outsize = 0
  let res = getUVarint(data, outsize, result)
  if res != VarintStatus.Success:
    raise newException(VarintError, "Error '" & $res & "'")

when isMainModule:
  import unittest

  const edgeValues = [
    0'u64, (1'u64 shl 7) - 1'u64,
    (1'u64 shl 7), (1'u64 shl 14) - 1'u64,
    (1'u64 shl 14), (1'u64 shl 21) - 1'u64,
    (1'u64 shl 21), (1'u64 shl 28) - 1'u64,
    (1'u64 shl 28), (1'u64 shl 35) - 1'u64,
    (1'u64 shl 35), (1'u64 shl 42) - 1'u64,
    (1'u64 shl 42), (1'u64 shl 49) - 1'u64,
    (1'u64 shl 49), (1'u64 shl 56) - 1'u64,
    (1'u64 shl 56), (1'u64 shl 63) - 1'u64,
    (1'u64 shl 63), 0xFFFF_FFFF_FFFF_FFFF'u64
  ]
  const edgeSizes = [
    1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10
  ]

  suite "Variable integer test suite":

    test "vsizeof() edge cases test":
      for i in 0..<len(edgeValues):
        check vsizeof(edgeValues[i]) == edgeSizes[i]

    test "Success edge cases test":
      var buffer = newSeq[byte]()
      var length = 0
      var value = 0'u64
      for i in 0..<len(edgeValues):
        buffer.setLen(edgeSizes[i])
        check:
          putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
          getUVarint(buffer, length, value) == VarintStatus.Success
          value == edgeValues[i]

    test "Buffer Overrun edge cases test":
      var buffer = newSeq[byte]()
      var length = 0
      for i in 0..<len(edgeValues):
        buffer.setLen(edgeSizes[i] - 1)
        let res = putUVarint(buffer, length, edgeValues[i])
        check:
          res == VarintStatus.Overrun
          length == edgeSizes[i]

    test "Buffer Incomplete edge cases test":
      var buffer = newSeq[byte]()
      var length = 0
      var value = 0'u64
      for i in 0..<len(edgeValues):
        buffer.setLen(edgeSizes[i])
        check putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
        buffer.setLen(len(buffer) - 1)
        check:
          getUVarint(buffer, length, value) == VarintStatus.Incomplete

    test "Integer Overflow 32bit test":
      var buffer = newSeq[byte]()
      var length = 0
      for i in 0..<len(edgeValues):
        if edgeSizes[i] > 5:
          var value = 0'u32
          buffer.setLen(edgeSizes[i])
          check:
            putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
            getUVarint(buffer, length, value) == VarintStatus.Overflow

    test "Integer Overflow 64bit test":
      var buffer = newSeq[byte]()
      var length = 0
      for i in 0..<len(edgeValues):
        if edgeSizes[i] > 9:
          var value = 0'u64
          buffer.setLen(edgeSizes[i] + 1)
          check:
            putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
          buffer[9] = buffer[9] or 0x80'u8
          buffer[10] = 0x01'u8
          check:
            getUVarint(buffer, length, value) == VarintStatus.Overflow
