## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements minimal Google's ProtoBuf primitives.
import ../varint

const
  MaxMessageSize* = 1'u shl 22

type
  ProtoFieldKind* = enum
    ## Protobuf's field types enum
    Varint, Fixed64, Length, StartGroup, EndGroup, Fixed32

  ProtoFlags* = enum
    ## Protobuf's encoding types
    WithVarintLength, WithUint32BeLength, WithUint32LeLength

  ProtoBuffer* = object
    ## Protobuf's message representation object
    options: set[ProtoFlags]
    buffer*: seq[byte]
    offset*: int
    length*: int

  ProtoField* = object
    ## Protobuf's message field representation object
    index: int
    case kind: ProtoFieldKind
    of Varint:
      vint*: uint64
    of Fixed64:
      vfloat64*: float64
    of Length:
      vbuffer*: seq[byte]
    of Fixed32:
      vfloat32*: float32
    of StartGroup, EndGroup:
      discard

template protoHeader*(index: int, wire: ProtoFieldKind): uint =
  ## Get protobuf's field header integer for ``index`` and ``wire``.
  ((uint(index) shl 3) or cast[uint](wire))

template protoHeader*(field: ProtoField): uint =
  ## Get protobuf's field header integer for ``field``.
  ((uint(field.index) shl 3) or cast[uint](field.kind))

template toOpenArray*(pb: ProtoBuffer): untyped =
  toOpenArray(pb.buffer, pb.offset, len(pb.buffer) - 1)

template isEmpty*(pb: ProtoBuffer): bool =
  len(pb.buffer) - pb.offset <= 0

template isEnough*(pb: ProtoBuffer, length: int): bool =
  len(pb.buffer) - pb.offset - length >= 0

template getPtr*(pb: ProtoBuffer): pointer =
  cast[pointer](unsafeAddr pb.buffer[pb.offset])

template getLen*(pb: ProtoBuffer): int =
  len(pb.buffer) - pb.offset

proc vsizeof*(field: ProtoField): int {.inline.} =
  ## Returns number of bytes required to store protobuf's field ``field``.
  result = vsizeof(protoHeader(field))
  case field.kind
  of ProtoFieldKind.Varint:
    result += vsizeof(field.vint)
  of ProtoFieldKind.Fixed64:
    result += sizeof(field.vfloat64)
  of ProtoFieldKind.Fixed32:
    result += sizeof(field.vfloat32)
  of ProtoFieldKind.Length:
    result += vsizeof(uint(len(field.vbuffer))) + len(field.vbuffer)
  else:
    discard

proc initProtoField*(index: int, value: SomeVarint): ProtoField =
  ## Initialize ProtoField with integer value.
  result = ProtoField(kind: Varint, index: index)
  when type(value) is uint64:
    result.vint = value
  else:
    result.vint = cast[uint64](value)

proc initProtoField*(index: int, value: bool): ProtoField =
  ## Initialize ProtoField with integer value.
  result = ProtoField(kind: Varint, index: index)
  result.vint = byte(value)

proc initProtoField*(index: int, value: openarray[byte]): ProtoField =
  ## Initialize ProtoField with bytes array.
  result = ProtoField(kind: Length, index: index)
  if len(value) > 0:
    result.vbuffer = newSeq[byte](len(value))
    copyMem(addr result.vbuffer[0], unsafeAddr value[0], len(value))

proc initProtoField*(index: int, value: string): ProtoField =
  ## Initialize ProtoField with string.
  result = ProtoField(kind: Length, index: index)
  if len(value) > 0:
    result.vbuffer = newSeq[byte](len(value))
    copyMem(addr result.vbuffer[0], unsafeAddr value[0], len(value))

proc initProtoField*(index: int, value: ProtoBuffer): ProtoField {.inline.} =
  ## Initialize ProtoField with nested message stored in ``value``.
  ##
  ## Note: This procedure performs shallow copy of ``value`` sequence.
  result = ProtoField(kind: Length, index: index)
  if len(value.buffer) > 0:
    shallowCopy(result.vbuffer, value.buffer)

proc initProtoBuffer*(data: seq[byte], offset = 0,
                      options: set[ProtoFlags] = {}): ProtoBuffer =
  ## Initialize ProtoBuffer with shallow copy of ``data``.
  shallowCopy(result.buffer, data)
  result.offset = offset
  result.options = options

proc initProtoBuffer*(options: set[ProtoFlags] = {}): ProtoBuffer =
  ## Initialize ProtoBuffer with new sequence of capacity ``cap``.
  result.buffer = newSeqOfCap[byte](128)
  result.options = options
  if WithVarintLength in options:
    # Our buffer will start from position 10, so we can store length of buffer
    # in [0, 9].
    result.buffer.setLen(10)
    result.offset = 10
  elif {WithUint32LeLength, WithUint32BeLength} * options != {}:
    # Our buffer will start from position 4, so we can store length of buffer
    # in [0, 9].
    result.buffer.setLen(4)
    result.offset = 4

proc write*(pb: var ProtoBuffer, field: ProtoField) =
  ## Encode protobuf's field ``field`` and store it to protobuf's buffer ``pb``.
  var length = 0
  var res: VarintStatus
  pb.buffer.setLen(len(pb.buffer) + vsizeof(field))
  res = PB.putUVarint(pb.toOpenArray(), length, protoHeader(field))
  doAssert(res == VarintStatus.Success)
  pb.offset += length
  case field.kind
  of ProtoFieldKind.Varint:
    res = PB.putUVarint(pb.toOpenArray(), length, field.vint)
    doAssert(res == VarintStatus.Success)
    pb.offset += length
  of ProtoFieldKind.Fixed64:
    doAssert(pb.isEnough(8))
    var value = cast[uint64](field.vfloat64)
    pb.buffer[pb.offset] = byte(value and 0xFF'u32)
    pb.buffer[pb.offset + 1] = byte((value shr 8) and 0xFF'u32)
    pb.buffer[pb.offset + 2] = byte((value shr 16) and 0xFF'u32)
    pb.buffer[pb.offset + 3] = byte((value shr 24) and 0xFF'u32)
    pb.buffer[pb.offset + 4] = byte((value shr 32) and 0xFF'u32)
    pb.buffer[pb.offset + 5] = byte((value shr 40) and 0xFF'u32)
    pb.buffer[pb.offset + 6] = byte((value shr 48) and 0xFF'u32)
    pb.buffer[pb.offset + 7] = byte((value shr 56) and 0xFF'u32)
    pb.offset += 8
  of ProtoFieldKind.Fixed32:
    doAssert(pb.isEnough(4))
    var value = cast[uint32](field.vfloat32)
    pb.buffer[pb.offset] = byte(value and 0xFF'u32)
    pb.buffer[pb.offset + 1] = byte((value shr 8) and 0xFF'u32)
    pb.buffer[pb.offset + 2] = byte((value shr 16) and 0xFF'u32)
    pb.buffer[pb.offset + 3] = byte((value shr 24) and 0xFF'u32)
    pb.offset += 4
  of ProtoFieldKind.Length:
    res = PB.putUVarint(pb.toOpenArray(), length, uint(len(field.vbuffer)))
    doAssert(res == VarintStatus.Success)
    pb.offset += length
    doAssert(pb.isEnough(len(field.vbuffer)))
    if len(field.vbuffer) > 0:
      copyMem(addr pb.buffer[pb.offset], unsafeAddr field.vbuffer[0],
              len(field.vbuffer))
      pb.offset += len(field.vbuffer)
  else:
    discard

proc finish*(pb: var ProtoBuffer) =
  ## Prepare protobuf's buffer ``pb`` for writing to stream.
  doAssert(len(pb.buffer) > 0)
  if WithVarintLength in pb.options:
    let size = uint(len(pb.buffer) - 10)
    let pos = 10 - vsizeof(size)
    var usedBytes = 0
    let res = PB.putUVarint(pb.buffer.toOpenArray(pos, 9), usedBytes, size)
    doAssert(res == VarintStatus.Success)
    pb.offset = pos
  elif WithUint32BeLength in pb.options:
    let size = uint(len(pb.buffer) - 4)
    pb.buffer[0] = byte(size shr 24)
    pb.buffer[1] = byte(size shr 16)
    pb.buffer[2] = byte(size shr 8)
    pb.buffer[3] = byte(size)
    pb.offset = 4
  elif WithUint32LeLength in pb.options:
    let size = uint(len(pb.buffer) - 4)
    pb.buffer[0] = byte(size)
    pb.buffer[1] = byte(size shr 8)
    pb.buffer[2] = byte(size shr 16)
    pb.buffer[3] = byte(size shr 24)
    pb.offset = 4
  else:
    pb.offset = 0

proc getVarintValue*(data: var ProtoBuffer, field: int,
                     value: var SomeVarint): int =
  ## Get value of `Varint` type.
  var length = 0
  var header = 0'u64
  var soffset = data.offset

  if not data.isEmpty() and
     PB.getUVarint(data.toOpenArray(), length, header) == VarintStatus.Success:
    data.offset += length
    if header == protoHeader(field, Varint):
      if not data.isEmpty():
        when type(value) is int32 or type(value) is int64 or type(value) is int:
          let res = getSVarint(data.toOpenArray(), length, value)
        else:
          let res = PB.getUVarint(data.toOpenArray(), length, value)
        if res == VarintStatus.Success:
          data.offset += length
          result = length
          return
  # Restore offset on error
  data.offset = soffset

proc getLengthValue*[T: string|seq[byte]](data: var ProtoBuffer, field: int,
                                          buffer: var T): int =
  ## Get value of `Length` type.
  var length = 0
  var header = 0'u64
  var ssize = 0'u64
  var soffset = data.offset
  result = -1
  buffer.setLen(0)
  if not data.isEmpty() and
     PB.getUVarint(data.toOpenArray(), length, header) == VarintStatus.Success:
    data.offset += length
    if header == protoHeader(field, Length):
      if not data.isEmpty() and
         PB.getUVarint(data.toOpenArray(), length, ssize) == VarintStatus.Success:
        data.offset += length
        if ssize <= MaxMessageSize and data.isEnough(int(ssize)):
          buffer.setLen(ssize)
          # Protobuf allow zero-length values.
          if ssize > 0'u64:
            copyMem(addr buffer[0], addr data.buffer[data.offset], ssize)
          result = int(ssize)
          data.offset += int(ssize)
          return
  # Restore offset on error
  data.offset = soffset

proc getBytes*(data: var ProtoBuffer, field: int,
               buffer: var seq[byte]): int {.inline.} =
  ## Get value of `Length` type as bytes.
  result = getLengthValue(data, field, buffer)

proc getString*(data: var ProtoBuffer, field: int,
                buffer: var string): int {.inline.} =
  ## Get value of `Length` type as string.
  result = getLengthValue(data, field, buffer)

proc enterSubmessage*(pb: var ProtoBuffer): int =
  ## Processes protobuf's sub-message and adjust internal offset to enter
  ## inside of sub-message. Returns field index of sub-message field or
  ## ``0`` on error.
  var length = 0
  var header = 0'u64
  var msize = 0'u64
  var soffset = pb.offset

  if not pb.isEmpty() and
     PB.getUVarint(pb.toOpenArray(), length, header) == VarintStatus.Success:
    pb.offset += length
    if (header and 0x07'u64) == cast[uint64](ProtoFieldKind.Length):
      if not pb.isEmpty() and
         PB.getUVarint(pb.toOpenArray(), length, msize) == VarintStatus.Success:
        pb.offset += length
        if msize <= MaxMessageSize and pb.isEnough(int(msize)):
          pb.length = int(msize)
          result = int(header shr 3)
          return
  # Restore offset on error
  pb.offset = soffset

proc skipSubmessage*(pb: var ProtoBuffer) =
  ## Skip current protobuf's sub-message and adjust internal offset to the
  ## end of sub-message.
  doAssert(pb.length != 0)
  pb.offset += pb.length
  pb.length = 0
