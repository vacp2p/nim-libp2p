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
##   https://developers.google.com/protocol-buffers/docs/encoding#varints
## - LibP2P varint, which is able to encode only 63bits of uint64 number and
##   maximum size of encoded value is 9 octets (bytes).
##   https://github.com/multiformats/unsigned-varint

{.push raises: [Defect].}

import bitops, typetraits
import stew/results
export results

type
  VarintError* {.pure.} = enum
    Error,
    Overflow,
    Incomplete,
    Overlong,
    Overrun

  VarintResult*[T] = Result[T, VarintError]

  PB* = object
    ## Use this type to specify Google ProtoBuf's varint encoding
  LP* = object
    ## Use this type to specify LibP2P varint encoding

  zint32* = distinct int32
  zint64* = distinct int64
  zint* = distinct int
    ## Signed integer types which will be encoded using zigzag encoding.

  hint32* = distinct int32
  hint64* = distinct int64
  hint* = distinct int
    ## Signed integer types which will be encoded using simple cast.

  PBSomeUVarint* = uint | uint64 | uint32
  PBSomeSVarint* = hint | hint64 | hint32
  PBZigVarint* = zint | zint64 | zint32
  PBSomeVarint* = PBSomeUVarint | PBSomeSVarint | PBZigVarint
  LPSomeUVarint* = uint | uint64 | uint32 | uint16 | uint8
  LPSomeVarint* = LPSomeUVarint
  SomeVarint* = PBSomeVarint | LPSomeVarint
  SomeUVarint* = PBSomeUVarint | LPSomeUVarint

proc vsizeof*(x: SomeUVarint): int {.inline.} =
  ## Returns number of bytes required to encode integer ``x`` as varint.
  if x == type(x)(0):
    1
  else:
    (fastLog2(x) + 1 + 7 - 1) div 7

proc vsizeof*(x: PBSomeSVarint): int {.inline.} =
  ## Returns number of bytes required to encode signed integer ``x``.
  ##
  ## Note: This procedure interprets signed integer as ProtoBuffer's
  ## ``int32`` and ``int64`` integers.
  when sizeof(x) == 8:
    if int64(x) == 0'i64:
      1
    else:
      (fastLog2(uint64(x)) + 1 + 7 - 1) div 7
  else:
    if int32(x) == 0'i32:
      1
    else:
      (fastLog2(uint32(x)) + 1 + 7 - 1) div 7

proc vsizeof*(x: PBZigVarint): int {.inline.} =
  ## Returns number of bytes required to encode signed integer ``x``.
  ##
  ## Note: This procedure interprets signed integer as ProtoBuffer's
  ## ``sint32`` and ``sint64`` integer.
  when sizeof(x) == 8:
    if int64(x) == 0'i64:
      1
    else:
      if int64(x) < 0'i64:
        vsizeof(not(uint64(x) shl 1))
      else:
        vsizeof(uint64(x) shl 1)
  else:
    if int32(x) == 0'i32:
      1
    else:
      if int32(x) < 0'i32:
        vsizeof(not(uint32(x) shl 1))
      else:
        vsizeof(uint32(x) shl 1)

proc getUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: openarray[byte],
                           outlen: var int,
                           outval: var SomeUVarint): VarintResult[void] =
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
  outlen = 0
  outval = type(outval)(0)
  for i in 0..<len(pbytes):
    let b = pbytes[i]
    if shift >= MaxBits:
      outlen = 0
      outval = type(outval)(0)
      return err(VarintError.Overflow)
    else:
      outval = outval or (type(outval)(b and 0x7F'u8) shl shift)
      shift += 7
    inc(outlen)
    if (b and 0x80'u8) == 0'u8:
      # done, success
      if outlen != vsizeof(outval):
        outval = type(outval)(0)
        outlen = 0
        return err(VarintError.Overlong)
      else:
        return ok()
  
  outlen = 0
  outval = type(outval)(0)
  err(VarintError.Incomplete)

proc putUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: var openarray[byte],
                           outlen: var int,
                           outval: SomeUVarint): VarintResult[void] =
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
      if (uint64(outval) and 0x8000_0000_0000_0000'u64) != 0'u64:
        return err(VarintError.Overflow)

  if value <= type(outval)(0x7F):
    buffer[0] = byte(outval and 0xFF)
    inc(k)
  else:
    while value != type(outval)(0):
      buffer[k] = byte((value and 0x7F) or 0x80)
      value = value shr 7
      inc(k)
    buffer[k - 1] = buffer[k - 1] and 0x7F'u8

  outlen = k
  if len(pbytes) >= k:
    copyMem(addr pbytes[0], addr buffer[0], k)
    ok()
  else:
    err(VarintError.Overrun)

proc getSVarint*(pbytes: openarray[byte], outsize: var int,
                 outval: var PBSomeSVarint): VarintResult[void] {.inline.} =
  ## Decode signed integer (``int32`` or ``int64``) from buffer ``pbytes``
  ## and store it to ``outval``.
  ##
  ## On success ``outlen`` will be set to number of bytes processed while
  ## decoding signed varint.
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

  let res = PB.getUVarint(pbytes, outsize, value)
  if res.isOk():
    outval = cast[type(outval)](value)
  res

proc getSVarint*(pbytes: openarray[byte], outsize: var int,
                 outval: var PBZigVarint): VarintResult[void] {.inline.} =
  ## Decode Google ProtoBuf's zigzag encoded signed integer (``sint32`` or
  ## ``sint64`` ) from buffer ``pbytes`` and store it to ``outval``.
  ##
  ## On success ``outlen`` will be set to number of bytes processed while
  ## decoding signed varint.
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

  let res = PB.getUVarint(pbytes, outsize, value)
  if res.isOk():
    if (value and type(value)(1)) != type(value)(0):
      outval = cast[type(outval)](not(value shr 1))
    else:
      outval = cast[type(outval)](value shr 1)
  res

proc putSVarint*(pbytes: var openarray[byte], outsize: var int,
                 outval: PBZigVarint): VarintResult[void] {.inline.} =
  ## Encode signed integer ``outval`` using ProtoBuffer's zigzag encoding
  ## (``sint32`` or ``sint64``) and store it to array ``pbytes``.
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
      if int64(outval) < 0'i64:
        not(uint64(outval) shl 1)
      else:
        uint64(outval) shl 1
  else:
    var value: uint32 =
      if int32(outval) < 0'i32:
        not(uint32(outval) shl 1)
      else:
        uint32(outval) shl 1
  PB.putUVarint(pbytes, outsize, value)

proc putSVarint*(pbytes: var openarray[byte], outsize: var int,
                 outval: PBSomeSVarint): VarintResult[void] {.inline.} =
  ## Encode signed integer ``outval`` (``int32`` or ``int64``) and store it to
  ## array ``pbytes``.
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
    PB.putUVarint(pbytes, outsize, uint64(outval))
  else:
    PB.putUVarint(pbytes, outsize, uint32(outval))

template varintFatal(msg) =
  const m = msg
  {.fatal: m.}

proc putVarint*[T: PB|LP](vtype: typedesc[T], pbytes: var openarray[byte],
                nbytes: var int, value: SomeVarint): VarintResult[void] {.inline.} =
  when vtype is PB:
    when (type(value) is PBSomeSVarint) or (type(value) is PBZigVarint):
      putSVarint(pbytes, nbytes, value)
    elif (type(value) is PBSomeUVarint):
      PB.putUVarint(pbytes, nbytes, value)
    else:
      varintFatal("Protobuf's varint do not support type [" &
                  typetraits.name(type(value)) & "]")
  elif vtype is LP:
    when (type(value) is LPSomeVarint):
      LP.putUVarint(pbytes, nbytes, value)
    else:
      varintFatal("LibP2P's varint do not support type [" &
                   typetraits.name(type(value)) & "]")

proc getVarint*[T: PB|LP](vtype: typedesc[T], pbytes: openarray[byte],
                          nbytes: var int,
                          value: var SomeVarint): VarintResult[void] {.inline.} =
  when vtype is PB:
    when (type(value) is PBSomeSVarint) or (type(value) is PBZigVarint):
      getSVarint(pbytes, nbytes, value)
    elif (type(value) is PBSomeUVarint):
      PB.getUVarint(pbytes, nbytes, value)
    else:
      varintFatal("Protobuf's varint do not support type [" &
                  typetraits.name(type(value)) & "]")
  elif vtype is LP:
    when (type(value) is LPSomeVarint):
      LP.getUVarint(pbytes, nbytes, value)
    else:
      varintFatal("LibP2P's varint do not support type [" &
                   typetraits.name(type(value)) & "]")

proc encodeVarint*(vtype: typedesc[PB],
                   value: PBSomeVarint): VarintResult[seq[byte]] {.inline.} =
  ## Encode integer to Google ProtoBuf's `signed/unsigned varint` and returns
  ## sequence of bytes as buffer.
  var outsize = 0
  var buffer = newSeqOfCap[byte](10)
  when sizeof(value) == 4:
    buffer.setLen(5)
  else:
    buffer.setLen(10)
  when (type(value) is PBSomeSVarint) or (type(value) is PBZigVarint):
    let res = putSVarint(buffer, outsize, value)
  else:
    let res = PB.putUVarint(buffer, outsize, value)
  if res.isOk():
    buffer.setLen(outsize)
    ok(buffer)
  else:
    err(res.error())
  

proc encodeVarint*(vtype: typedesc[LP],
                   value: LPSomeVarint): VarintResult[seq[byte]] {.inline.} =
  ## Encode integer to LibP2P `unsigned varint` and returns sequence of bytes
  ## as buffer.
  var outsize = 0
  var buffer = newSeqOfCap[byte](9)
  when sizeof(value) == 1:
    buffer.setLen(2)
  elif sizeof(value) == 2:
    buffer.setLen(3)
  elif sizeof(value) == 4:
    buffer.setLen(5)
  else:
    buffer.setLen(9)
  let res = LP.putUVarint(buffer, outsize, value)
  if res.isOk():
    buffer.setLen(outsize)
    ok(buffer)
  else:
    err(res.error)
