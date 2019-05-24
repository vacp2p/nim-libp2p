## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Variable Integer `VARINT`.
## This module supports two variants of variable integer
## - Google ProtoBuf varint, which is able to encode full uint64 number and
##   maximum size of encoded value is 10 octets (bytes).
## - LibP2P varint, which is able to encode only 63bits of uint64 number and
##   maximum size of encoded value is 9 octets (bytes).
import bitops

type
  VarintStatus* {.pure.} = enum
    Error,
    Success,
    Overflow,
    Incomplete,
    Overrun

  PB* = object
    ## Use this type to specify Google ProtoBuf's varint encoding
  LP* = object
    ## Use this type to specify LibP2P varint encoding

  PBSomeUVarint* = uint | uint64 | uint32
  PBSomeSVarint* = int | int64 | int32
  PBSomeVarint* = PBSomeUVarint | PBSomeSVarint
  LPSomeUVarint* = uint | uint64 | uint32 | uint16 | uint8
  LPSomeVarint* = LPSomeUVarint
  SomeVarint* = PBSomeVarint | LPSomeVarint
  SomeUVarint* = PBSomeUVarint | LPSomeUVarint
  VarintError* = object of Exception

proc vsizeof*(x: SomeVarint): int {.inline.} =
  ## Returns number of bytes required to encode integer ``x`` as varint.
  if x == cast[type(x)](0):
    result = 1
  else:
    result = (fastLog2(x) + 1 + 7 - 1) div 7

proc getUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: openarray[byte],
                           outlen: var int,
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
  ## Google ProtoBuf
  ## When decoding 10th byte of Google Protobuf's 64bit integer only 1 bit from
  ## byte will be decoded, all other bits will be ignored. When decoding 5th
  ## byte of 32bit integer only 4 bits from byte will be decoded, all other bits
  ## will be ignored.
  ## 
  ## LibP2P
  ## When decoding 5th byte of 32bit integer only 4 bits from byte will be
  ## decoded, all other bits will be ignored.
  when vtype is PB:
    const MaxBits = byte(sizeof(outval) * 8)
  else:
    when sizeof(outval) == 8:
      const MaxBits = 63'u8
    else:
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

proc putUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: var openarray[byte],
                           outlen: var int,
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
  ## Google ProtoBuf
  ## Maximum encoded length of 64bit integer is 10 octets.
  ## Maximum encoded length of 32bit integer is 5 octets.
  ## 
  ## LibP2P
  ## Maximum encoded length of 63bit integer is 9 octets.
  ## Maximum encoded length of 32bit integer is 5 octets.
  var buffer: array[10, byte]
  var value = outval
  var k = 0

  when vtype is LP:
    if sizeof(outval) == 8:
      if (cast[uint64](outval) and 0x8000_0000_0000_0000'u64) != 0'u64:
        result = Overflow
        return

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
                 outval: var PBSomeSVarint): VarintStatus {.inline.} =
  ## Decode Google ProtoBuf's `signed varint` from buffer ``pbytes`` and store
  ## it to ``outval``. On success ``outlen`` will be set to number of bytes
  ## processed while decoding `signed varint`.
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

  result = PB.getUVarint(pbytes, outsize, value)
  if result == VarintStatus.Success:
    if (value and cast[type(value)](1)) != cast[type(value)](0):
      outval = cast[type(outval)](not(value shr 1))
    else:
      outval = cast[type(outval)](value shr 1)

proc putSVarint*(pbytes: var openarray[byte], outsize: var int,
                 outval: PBSomeSVarint): VarintStatus {.inline.} =
  ## Encode Google ProtoBuf's `signed varint` ``outval`` and store it to array
  ## ``pbytes``.
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
  result = PB.putUVarint(pbytes, outsize, value)

proc encodeVarint*(vtype: typedesc[PB],
                   value: SomeVarint): seq[byte] {.inline.} =
  ## Encode integer to Google ProtoBuf's `signed/unsigned varint` and returns
  ## sequence of bytes as result.
  var outsize = 0
  result = newSeqOfCap[byte](10)
  when sizeof(value) == 4:
    result.setLen(5)
  else:
    result.setLen(10)
  when type(value) is PBSomeSVarint:
    let res = putSVarint(result, outsize, value)
  else:
    let res = putUVarint(result, outsize, value)
  if res == VarintStatus.Success:
    result.setLen(outsize)
  else:
    raise newException(VarintError, "Error '" & $res & "'")

proc encodeVarint*(vtype: typedesc[LP],
                   value: LPSomeVarint): seq[byte] {.inline.} =
  ## Encode integer to LibP2P `unsigned varint` and returns sequence of bytes
  ## as result.
  var outsize = 0
  result = newSeqOfCap[byte](9)
  when sizeof(value) == 1:
    result.setLen(2)
  elif sizeof(value) == 2:
    result.setLen(3)
  elif sizeof(value) == 4:
    result.setLen(5)
  else:
    result.setLen(9)
  let res = LP.putUVarint(result, outsize, value)
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

proc decodeUVarint*[T: PB|LP](vtype: typedesc[T],
                              data: openarray[byte]): uint {.inline.} =
  ## Decode unsigned integer from array ``data`` and return it as result.
  var outsize = 0
  let res = vtype.getUVarint(data, outsize, result)
  if res != VarintStatus.Success:
    raise newException(VarintError, "Error '" & $res & "'")
