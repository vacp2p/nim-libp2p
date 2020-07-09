## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements minimal Google's ProtoBuf primitives.

{.push raises: [Defect].}

import ../varint, stew/endians2

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

  ProtoHeader* = object
    wire*: ProtoFieldKind
    index*: int64

  ProtoField* = object
    ## Protobuf's message field representation object
    index*: int64
    case kind*: ProtoFieldKind
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

  ProtoResult {.pure.} = enum
    VarintDecodeError,
    MessageIncompleteError,
    BufferOverflowError,
    MessageSizeTooBigError,
    NoError

template getProtoHeader*(index: int64, wire: ProtoFieldKind): uint64 =
  ## Get protobuf's field header integer for ``index`` and ``wire``.
  ((uint64(index) shl 3) or cast[uint64](wire))

template getProtoHeader*(field: ProtoField): uint =
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
  result = vsizeof(getProtoHeader(field))
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

proc initProtoField*(index: int, value: SomeVarint): ProtoField {.deprecated.} =
  ## Initialize ProtoField with integer value.
  result = ProtoField(kind: Varint, index: index)
  when type(value) is uint64:
    result.vint = value
  else:
    result.vint = cast[uint64](value)

proc initProtoField*(index: int, value: bool): ProtoField {.deprecated.} =
  ## Initialize ProtoField with integer value.
  result = ProtoField(kind: Varint, index: index)
  result.vint = byte(value)

proc initProtoField*(index: int,
                     value: openarray[byte]): ProtoField {.deprecated.} =
  ## Initialize ProtoField with bytes array.
  result = ProtoField(kind: Length, index: index)
  if len(value) > 0:
    result.vbuffer = newSeq[byte](len(value))
    copyMem(addr result.vbuffer[0], unsafeAddr value[0], len(value))

proc initProtoField*(index: int, value: string): ProtoField {.deprecated.} =
  ## Initialize ProtoField with string.
  result = ProtoField(kind: Length, index: index)
  if len(value) > 0:
    result.vbuffer = newSeq[byte](len(value))
    copyMem(addr result.vbuffer[0], unsafeAddr value[0], len(value))

proc initProtoField*(index: int,
                     value: ProtoBuffer): ProtoField {.deprecated, inline.} =
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

proc initProtoBuffer*(data: openarray[byte], offset = 0,
                      options: set[ProtoFlags] = {}): ProtoBuffer =
  ## Initialize ProtoBuffer with shallow copy of ``data``.
  result.buffer = @data
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

proc write*[T: uint64|float32|float64](pb: var ProtoBuffer, field: int64,
                                       value: T) =
  var length = 0
  let flength =
    when T is uint64:
      vsizeof(getProtoHeader(field, ProtoFieldKind.Varint)) + vsizeof(value)
    elif T is float32:
      vsizeof(getProtoHeader(field, ProtoFieldKind.Fixed32)) + sizeof(T)
    elif T is float64:
      vsizeof(getProtoHeader(field, ProtoFieldKind.Fixed64)) + sizeof(T)
  let header =
    when T is uint64:
      ProtoFieldKind.Varint
    elif T is float32:
      ProtoFieldKind.Fixed32
    elif T is float64:
      ProtoFieldKind.Fixed64

  pb.buffer.setLen(len(pb.buffer) + flength)

  let hres = PB.putUVarint(pb.toOpenArray(), length,
                           getProtoHeader(field, header))
  doAssert(hres.isOk())
  pb.offset += length
  when T is uint64:
    let vres = PB.putUVarint(pb.toOpenArray(), length, value)
    doAssert(vres.isOk())
    pb.offset += length
  elif T is float32:
    doAssert(pb.isEnough(sizeof(T)))
    let u32 = cast[uint32](value)
    pb.buffer[pb.offset ..< pb.offset + sizeof(T)] = u32.toBytesLE()
    pb.offset += sizeof(T)
  elif T is float64:
    doAssert(pb.isEnough(sizeof(T)))
    let u64 = cast[uint64](value)
    pb.buffer[pb.offset ..< pb.offset + sizeof(T)] = u64.toBytesLE()
    pb.offset += sizeof(T)

proc writePacked*[T: uint64|float32|float64](pb: var ProtoBuffer, field: int64,
                                             value: openarray[T]) =
  var length = 0
  var dlength = 0
  when T is uint64:
    for item in value:
      dlength += vsizeof(item)
  elif T is float32:
    dlength = len(value) * sizeof(T)
  elif T is float64:
    dlength = len(value) * sizeof(T)

  let header = getProtoHeader(field, ProtoFieldKind.Length)
  let flength = vsizeof(header) + vsizeof(uint64(dlength)) + dlength
  pb.buffer.setLen(len(pb.buffer) + flength)
  let hres = PB.putUVarint(pb.toOpenArray(), length, header)
  doAssert(hres.isOk())
  pb.offset += length
  length = 0
  let lres = PB.putUVarint(pb.toOpenArray(), length, uint64(dlength))
  doAssert(lres.isOk())
  pb.offset += length
  for item in value:
    when T is uint64:
      length = 0
      let vres = PB.putUVarint(pb.toOpenArray(), length, item)
      doAssert(vres.isOk())
      pb.offset += length
    elif T is float32:
      doAssert(pb.isEnough(sizeof(T)))
      let u32 = cast[uint32](item)
      pb.buffer[pb.offset ..< pb.offset + sizeof(T)] = u32.toBytesLE()
      pb.offset += sizeof(T)
    elif T is float64:
      doAssert(pb.isEnough(sizeof(T)))
      let u64 = cast[uint64](item)
      pb.buffer[pb.offset ..< pb.offset + sizeof(T)] = u64.toBytesLE()
      pb.offset += sizeof(T)

proc write*[T: byte|char](pb: var ProtoBuffer, field: int64,
                          value: openarray[T]) =
  var length = 0
  let flength = vsizeof(getProtoHeader(field, ProtoFieldKind.Length)) +
                vsizeof(uint64(len(value))) + len(value)
  pb.buffer.setLen(len(pb.buffer) + flength)
  let hres = PB.putUVarint(pb.toOpenArray(), length,
                           getProtoHeader(field, ProtoFieldKind.Length))
  doAssert(hres.isOk())
  pb.offset += length
  let lres = PB.putUVarint(pb.toOpenArray(), length,
                           uint64(len(value)))
  doAssert(lres.isOk())
  pb.offset += length
  if len(value) > 0:
    doAssert(pb.isEnough(len(value)))
    copyMem(addr pb.buffer[pb.offset], unsafeAddr value[0], len(value))
    pb.offset += len(value)

proc write*(pb: var ProtoBuffer, field: int64, value: ProtoBuffer) {.inline.} =
  write(pb, field, value.buffer)

proc write*(pb: var ProtoBuffer, field: ProtoField) {.deprecated.} =
  ## Encode protobuf's field ``field`` and store it to protobuf's buffer ``pb``.
  var length = 0
  var res: VarintResult[void]
  pb.buffer.setLen(len(pb.buffer) + vsizeof(field))
  res = PB.putUVarint(pb.toOpenArray(), length, getProtoHeader(field))
  doAssert(res.isOk())
  pb.offset += length
  case field.kind
  of ProtoFieldKind.Varint:
    res = PB.putUVarint(pb.toOpenArray(), length, field.vint)
    doAssert(res.isOk())
    pb.offset += length
  of ProtoFieldKind.Fixed64:
    doAssert(pb.isEnough(8))
    var value = cast[uint64](field.vfloat64)
    pb.buffer[pb.offset] = byte(value and 0xFF'u32)
    pb.buffer[pb.offset + 1] = byte((value shr 8) and 0xFF'u64)
    pb.buffer[pb.offset + 2] = byte((value shr 16) and 0xFF'u64)
    pb.buffer[pb.offset + 3] = byte((value shr 24) and 0xFF'u64)
    pb.buffer[pb.offset + 4] = byte((value shr 32) and 0xFF'u64)
    pb.buffer[pb.offset + 5] = byte((value shr 40) and 0xFF'u64)
    pb.buffer[pb.offset + 6] = byte((value shr 48) and 0xFF'u64)
    pb.buffer[pb.offset + 7] = byte((value shr 56) and 0xFF'u64)
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
    doAssert(res.isOk())
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
    doAssert(res.isOk())
    pb.offset = pos
  elif WithUint32BeLength in pb.options:
    let size = uint(len(pb.buffer) - 4)
    pb.buffer[0 ..< 4] = toBytesBE(uint32(size))
    pb.offset = 4
  elif WithUint32LeLength in pb.options:
    let size = uint(len(pb.buffer) - 4)
    pb.buffer[0 ..< 4] = toBytesLE(uint32(size))
    pb.offset = 4
  else:
    pb.offset = 0

proc getHeader(data: var ProtoBuffer, header: var ProtoHeader): bool =
  var length = 0
  var hdr = 0'u64
  if PB.getUVarint(data.toOpenArray(), length, hdr).isOk():
    let index = int64(hdr shr 3)
    let wire = hdr and 0x07
    # We going to work only with Varint, Fixed32, Fixed64 and Length.
    if wire in {0, 1, 2, 5}:
      data.offset += length
      header = ProtoHeader(index: index, wire: cast[ProtoFieldKind](wire))
      true
    else:
      false
  else:
    false

proc skipValue(data: var ProtoBuffer, header: ProtoHeader): bool =
  case header.wire
  of ProtoFieldKind.Varint:
    var length = 0
    var value = 0'u64
    if PB.getUVarint(data.toOpenArray(), length, value).isOk():
      data.offset += length
      true
    else:
      false
  of ProtoFieldKind.Fixed32:
    if data.isEnough(sizeof(uint32)):
      data.offset += sizeof(uint32)
      true
    else:
      false
  of ProtoFieldKind.Fixed64:
    if data.isEnough(sizeof(uint64)):
      data.offset += sizeof(uint64)
      true
    else:
      false
  of ProtoFieldKind.Length:
    var length = 0
    var bsize = 0'u64
    if PB.getUVarint(data.toOpenArray(), length, bsize).isOk():
      data.offset += length
      if bsize <= uint64(MaxMessageSize):
        if data.isEnough(int(bsize)):
          data.offset += int(bsize)
          true
        else:
          false
      else:
        false
    else:
      false
  of ProtoFieldKind.StartGroup, ProtoFieldKind.EndGroup:
    false

proc getValue[T: float32|float64|uint64](data: var ProtoBuffer,
                                         header: ProtoHeader,
                                         outval: var T): ProtoResult =
  when T is uint64:
    doAssert(header.wire == ProtoFieldKind.Varint)
    var length = 0
    var value = 0'u64
    if PB.getUVarint(data.toOpenArray(), length, value).isOk():
      data.offset += length
      outval = value
      ProtoResult.NoError
    else:
      ProtoResult.VarintDecodeError
  elif T is float32:
    doAssert(header.wire == ProtoFieldKind.Fixed32)
    if data.isEnough(sizeof(float32)):
      outval = cast[float32](fromBytesLE(uint32, data.toOpenArray()))
      data.offset += sizeof(float32)
      ProtoResult.NoError
    else:
      ProtoResult.MessageIncompleteError
  elif T is float64:
    doAssert(header.wire == ProtoFieldKind.Fixed64)
    if data.isEnough(sizeof(uint64)):
      outval = cast[float64](fromBytesLE(uint64, data.toOpenArray()))
      data.offset += sizeof(uint64)
      ProtoResult.NoError
    else:
      ProtoResult.MessageIncompleteError

proc getValue[T:byte|char](data: var ProtoBuffer, header: ProtoHeader,
                           outBytes: var openarray[T],
                           outLength: var int): ProtoResult =
  doAssert(header.wire == ProtoFieldKind.Length)
  var length = 0
  var bsize = 0'u64

  outLength = 0
  if PB.getUVarint(data.toOpenArray(), length, bsize).isOk():
    data.offset += length
    if bsize <= uint64(MaxMessageSize):
      if data.isEnough(int(bsize)):
        outLength = int(bsize)
        if len(outBytes) >= int(bsize):
          if bsize > 0'u64:
            copyMem(addr outBytes[0], addr data.buffer[data.offset], int(bsize))
          data.offset += int(bsize)
          ProtoResult.NoError
        else:
          # Buffer overflow should not be critical failure
          data.offset += int(bsize)
          ProtoResult.BufferOverflowError
      else:
        ProtoResult.MessageIncompleteError
    else:
      ProtoResult.MessageSizeTooBigError
  else:
    ProtoResult.VarintDecodeError

proc getValue[T:seq[byte]|string](data: var ProtoBuffer, header: ProtoHeader,
                                  outBytes: var T): ProtoResult =
  doAssert(header.wire == ProtoFieldKind.Length)
  var length = 0
  var bsize = 0'u64
  outBytes.setLen(0)

  if PB.getUVarint(data.toOpenArray(), length, bsize).isOk():
    data.offset += length
    if bsize <= uint64(MaxMessageSize):
      if data.isEnough(int(bsize)):
        outBytes.setLen(bsize)
        if bsize > 0'u64:
          copyMem(addr outBytes[0], addr data.buffer[data.offset], int(bsize))
        data.offset += int(bsize)
        ProtoResult.NoError
      else:
        ProtoResult.MessageIncompleteError
    else:
      ProtoResult.MessageSizeTooBigError
  else:
    ProtoResult.VarintDecodeError

proc getField*[T: uint64|float32|float64](data: ProtoBuffer, field: int64,
                                          output: var T): bool =
  var value: T
  var res = false
  var pb = data
  output = T(0)

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      output = T(0)
      return false
    let wireCheck =
      when T is uint64:
        header.wire == ProtoFieldKind.Varint
      elif T is float32:
        header.wire == ProtoFieldKind.Fixed32
      elif T is float64:
        header.wire == ProtoFieldKind.Fixed64
    if header.index == field:
      if wireCheck:
        let r = getValue(pb, header, value)
        case r
        of ProtoResult.NoError:
          res = true
          output = value
        else:
          return false
      else:
        # We are ignoring wire types different from what we expect, because it
        # is how `protoc` is working.
        if not(skipValue(pb, header)):
          output = T(0)
          return false
    else:
      if not(skipValue(pb, header)):
        output = T(0)
        return false
  res

proc getField*[T: byte|char](data: ProtoBuffer, field: int64,
                             output: var openarray[T],
                             outlen: var int): bool =
  var pb = data
  var res = false

  outlen = 0

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      if len(output) > 0:
        zeroMem(addr output[0], len(output))
      outlen = 0
      return false

    if header.index == field:
      if header.wire == ProtoFieldKind.Length:
        let r = getValue(pb, header, output, outlen)
        case r
        of ProtoResult.NoError:
          res = true
        of ProtoResult.BufferOverflowError:
          # Buffer overflow error is not critical error, we still can get
          # field values with proper size.
          discard
        else:
          if len(output) > 0:
            zeroMem(addr output[0], len(output))
          return false
      else:
        # We are ignoring wire types different from ProtoFieldKind.Length,
        # because it is how `protoc` is working.
        if not(skipValue(pb, header)):
          if len(output) > 0:
            zeroMem(addr output[0], len(output))
          outlen = 0
          return false
    else:
      if not(skipValue(pb, header)):
        if len(output) > 0:
          zeroMem(addr output[0], len(output))
        outlen = 0
        return false

  res

proc getField*[T: seq[byte]|string](data: ProtoBuffer, field: int64,
                                    output: var T): bool =
  var res = false
  var pb = data

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      output.setLen(0)
      return false

    if header.index == field:
      if header.wire == ProtoFieldKind.Length:
        let r = getValue(pb, header, output)
        case r
        of ProtoResult.NoError:
          res = true
        of ProtoResult.BufferOverflowError:
          # Buffer overflow error is not critical error, we still can get
          # field values with proper size.
          discard
        else:
          output.setLen(0)
          return false
      else:
        # We are ignoring wire types different from ProtoFieldKind.Length,
        # because it is how `protoc` is working.
        if not(skipValue(pb, header)):
          output.setLen(0)
          return false
    else:
      if not(skipValue(pb, header)):
        output.setLen(0)
        return false

  res

proc getRepeatedField*[T: seq[byte]|string](data: ProtoBuffer, field: int64,
                                            output: var seq[T]): bool =
  var pb = data
  output.setLen(0)

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      output.setLen(0)
      return false

    if header.index == field:
      if header.wire == ProtoFieldKind.Length:
        var item: T
        let r = getValue(pb, header, item)
        case r
        of ProtoResult.NoError:
          output.add(item)
        else:
          output.setLen(0)
          return false
      else:
        if not(skipValue(pb, header)):
          output.setLen(0)
          return false
    else:
      if not(skipValue(pb, header)):
        output.setLen(0)
        return false

  if len(output) > 0:
    true
  else:
    false

proc getRepeatedField*[T: uint64|float32|float64](data: ProtoBuffer,
                                                  field: int64,
                                                  output: var seq[T]): bool =
  var pb = data
  output.setLen(0)

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      output.setLen(0)
      return false

    if header.index == field:
      if header.wire in {ProtoFieldKind.Varint, ProtoFieldKind.Fixed32,
                         ProtoFieldKind.Fixed64}:
        var item: T
        let r = getValue(pb, header, item)
        case r
        of ProtoResult.NoError:
          output.add(item)
        else:
          output.setLen(0)
          return false
      else:
        if not(skipValue(pb, header)):
          output.setLen(0)
          return false
    else:
      if not(skipValue(pb, header)):
        output.setLen(0)
        return false

  if len(output) > 0:
    true
  else:
    false

proc getPackedRepeatedField*[T: uint64|float32|float64](data: ProtoBuffer,
                                                        field: int64,
                                                     output: var seq[T]): bool =
  var pb = data
  output.setLen(0)

  while not(pb.isEmpty()):
    var header: ProtoHeader
    if not(pb.getHeader(header)):
      output.setLen(0)
      return false

    if header.index == field:
      if header.wire == ProtoFieldKind.Length:
        var arritem: seq[byte]
        let rarr = getValue(pb, header, arritem)
        case rarr
        of ProtoResult.NoError:
          var pbarr = initProtoBuffer(arritem)
          let itemHeader =
            when T is uint64:
              ProtoHeader(wire: ProtoFieldKind.Varint)
            elif T is float32:
              ProtoHeader(wire: ProtoFieldKind.Fixed32)
            elif T is float64:
              ProtoHeader(wire: ProtoFieldKind.Fixed64)
          while not(pbarr.isEmpty()):
            var item: T
            let res = getValue(pbarr, itemHeader, item)
            case res
            of ProtoResult.NoError:
              output.add(item)
            else:
              output.setLen(0)
              return false
        else:
          output.setLen(0)
          return false
      else:
        if not(skipValue(pb, header)):
          output.setLen(0)
          return false
    else:
      if not(skipValue(pb, header)):
        output.setLen(0)
        return false

  if len(output) > 0:
    true
  else:
    false

proc getVarintValue*(data: var ProtoBuffer, field: int,
                     value: var SomeVarint): int {.deprecated.} =
  ## Get value of `Varint` type.
  var length = 0
  var header = 0'u64
  var soffset = data.offset

  if not data.isEmpty() and PB.getUVarint(data.toOpenArray(),
                                          length, header).isOk():
    data.offset += length
    if header == getProtoHeader(field, Varint):
      if not data.isEmpty():
        when type(value) is int32 or type(value) is int64 or type(value) is int:
          let res = getSVarint(data.toOpenArray(), length, value)
        else:
          let res = PB.getUVarint(data.toOpenArray(), length, value)
        if res.isOk():
          data.offset += length
          result = length
          return
  # Restore offset on error
  data.offset = soffset

proc getLengthValue*[T: string|seq[byte]](data: var ProtoBuffer, field: int,
                                          buffer: var T): int {.deprecated.} =
  ## Get value of `Length` type.
  var length = 0
  var header = 0'u64
  var ssize = 0'u64
  var soffset = data.offset
  result = -1
  buffer.setLen(0)
  if not data.isEmpty() and PB.getUVarint(data.toOpenArray(),
                                          length, header).isOk():
    data.offset += length
    if header == getProtoHeader(field, Length):
      if not data.isEmpty() and PB.getUVarint(data.toOpenArray(),
                                              length, ssize).isOk():
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
               buffer: var seq[byte]): int {.deprecated, inline.} =
  ## Get value of `Length` type as bytes.
  result = getLengthValue(data, field, buffer)

proc getString*(data: var ProtoBuffer, field: int,
                buffer: var string): int {.deprecated, inline.} =
  ## Get value of `Length` type as string.
  result = getLengthValue(data, field, buffer)

proc enterSubmessage*(pb: var ProtoBuffer): int {.deprecated.} =
  ## Processes protobuf's sub-message and adjust internal offset to enter
  ## inside of sub-message. Returns field index of sub-message field or
  ## ``0`` on error.
  var length = 0
  var header = 0'u64
  var msize = 0'u64
  var soffset = pb.offset

  if not pb.isEmpty() and PB.getUVarint(pb.toOpenArray(),
                                        length, header).isOk():
    pb.offset += length
    if (header and 0x07'u64) == cast[uint64](ProtoFieldKind.Length):
      if not pb.isEmpty() and PB.getUVarint(pb.toOpenArray(),
                                            length, msize).isOk():
        pb.offset += length
        if msize <= MaxMessageSize and pb.isEnough(int(msize)):
          pb.length = int(msize)
          result = int(header shr 3)
          return
  # Restore offset on error
  pb.offset = soffset

proc skipSubmessage*(pb: var ProtoBuffer) {.deprecated.} =
  ## Skip current protobuf's sub-message and adjust internal offset to the
  ## end of sub-message.
  doAssert(pb.length != 0)
  pb.offset += pb.length
  pb.length = 0
