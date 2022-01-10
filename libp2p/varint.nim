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

import stew/[byteutils, leb128, results]
export leb128, results

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

template toUleb(x: uint64): uint64 = x
template toUleb(x: uint32): uint32 = x
template toUleb(x: uint16): uint16 = x
template toUleb(x: uint8): uint8 = x

func toUleb(x: zint64): uint64 =
  let v = cast[uint64](x)
  (v shl 1) xor (0 - (v shr 63))

func toUleb(x: zint32): uint32 =
  let v = cast[uint32](x)
  (v shl 1) xor (0 - (v shr 31))

template toUleb(x: hint64): uint64 = cast[uint64](x)
template toUleb(x: hint32): uint32 = cast[uint32](x)

template toUleb(x: zint): uint64 =
  when sizeof(x) == sizeof(zint64):
    uint(toUleb(zint64(x)))
  else:
    uint(toUleb(zint32(x)))

template toUleb(x: hint): uint =
  when sizeof(x) == sizeof(hint64):
    uint(toUleb(hint64(x)))
  else:
    uint(toUleb(hint32(x)))

template fromUleb(x: uint64, T: type uint64): T = x
template fromUleb(x: uint32, T: type uint32): T = x

template fromUleb(x: uint64, T: type zint64): T =
  cast[T]((x shr 1) xor (0 - (x and 1)))

template fromUleb(x: uint32, T: type zint32): T =
  cast[T]((x shr 1) xor (0 - (x and 1)))

template fromUleb(x: uint64, T: type hint64): T =
  cast[T](x)

template fromUleb(x: uint32, T: type hint32): T =
  cast[T](x)

proc vsizeof*(x: SomeVarint): int {.inline.} =
  ## Returns number of bytes required to encode integer ``x`` as varint.
  Leb128.len(toUleb(x))

proc getUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: openArray[byte],
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
  outlen = 0
  outval = type(outval)(0)

  let parsed = type(outval).fromBytes(pbytes, Leb128)

  if parsed.len == 0:
    return err(VarintError.Incomplete)
  if parsed.len < 0:
    return err(VarintError.Overflow)

  when vtype is LP and sizeof(outval) == 8:
    if parsed.val >= 0x8000_0000_0000_0000'u64:
      return err(VarintError.Overflow)

  if vsizeof(parsed.val) != parsed.len:
    return err(VarintError.Overlong)

  (outval, outlen) = parsed

  ok()

proc putUVarint*[T: PB|LP](vtype: typedesc[T],
                           pbytes: var openArray[byte],
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
  when vtype is LP and sizeof(outval) == 8:
    if (uint64(outval) and 0x8000_0000_0000_0000'u64) != 0'u64:
      return err(VarintError.Overflow)

  let bytes = toBytes(outval, Leb128)
  outlen = len(bytes)
  if len(pbytes) >= outlen:
    pbytes[0..<outlen] = bytes.toOpenArray()
    ok()
  else:
    err(VarintError.Overrun)

proc getSVarint*(pbytes: openArray[byte], outsize: var int,
                 outval: var (PBZigVarint | PBSomeSVarint)): VarintResult[void] {.inline.} =
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
    outval = fromUleb(value, type(outval))
  res

proc putSVarint*(pbytes: var openArray[byte], outsize: var int,
                 outval: (PBZigVarint | PBSomeSVarint)): VarintResult[void] {.inline.} =
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
  PB.putUVarint(pbytes, outsize, toUleb(outval))

template varintFatal(msg) =
  const m = msg
  {.fatal: m.}

proc putVarint*[T: PB|LP](vtype: typedesc[T], pbytes: var openArray[byte],
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

proc getVarint*[T: PB|LP](vtype: typedesc[T], pbytes: openArray[byte],
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

template toBytes*(vtype: typedesc[PB], value: PBSomeVarint): auto =
  toBytes(toUleb(value), Leb128)

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
