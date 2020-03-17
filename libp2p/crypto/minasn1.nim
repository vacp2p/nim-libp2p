## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements minimal ASN.1 encoding/decoding primitives.
import stew/endians2
import nimcrypto/utils

type
  Asn1Status* {.pure.} = enum
    Error,
    Success,
    Overflow,
    Incomplete,
    Indefinite,
    Incorrect,
    NoSupport,
    Overrun

  Asn1Class* {.pure.} = enum
    Universal = 0x00,
    Application = 0x01
    ContextSpecific = 0x02
    Private = 0x03

  Asn1Tag* {.pure.} = enum
    ## Protobuf's field types enum
    NoSupport,
    Boolean,
    Integer,
    BitString,
    OctetString,
    Null,
    Oid,
    Sequence,
    Context

  Asn1Buffer* = object of RootObj
    ## ASN.1's message representation object
    buffer*: seq[byte]
    offset*: int
    length*: int

  Asn1Field* = object
    klass*: Asn1Class
    index*: int
    offset*: int
    length*: int
    buffer*: seq[byte]
    case kind*: Asn1Tag
    of Asn1Tag.Boolean:
      vbool*: bool
    of Asn1Tag.Integer:
      vint*: uint64
    of Asn1Tag.BitString:
      ubits*: int
    else:
      discard

  Asn1Composite* = object of Asn1Buffer
    tag*: Asn1Tag
    idx*: int

const
  Asn1OidSecp256r1* = [
    0x2A'u8, 0x86'u8, 0x48'u8, 0xCE'u8, 0x3D'u8, 0x03'u8, 0x01'u8, 0x07'u8
  ]
    ## Encoded OID for `secp256r1` curve (1.2.840.10045.3.1.7)
  Asn1OidSecp384r1* = [
    0x2B'u8, 0x81'u8, 0x04'u8, 0x00'u8, 0x22'u8
  ]
    ## Encoded OID for `secp384r1` curve (1.3.132.0.34)
  Asn1OidSecp521r1* = [
    0x2B'u8, 0x81'u8, 0x04'u8, 0x00'u8, 0x23'u8
  ]
    ## Encoded OID for `secp521r1` curve (1.3.132.0.35)
  Asn1OidSecp256k1* = [
    0x2B'u8, 0x81'u8, 0x04'u8, 0x00'u8, 0x0A'u8
  ]
    ## Encoded OID for `secp256k1` curve (1.3.132.0.10)
  Asn1OidEcPublicKey* = [
    0x2A'u8, 0x86'u8, 0x48'u8, 0xCE'u8, 0x3D'u8, 0x02'u8, 0x01'u8
  ]
    ## Encoded OID for Elliptic Curve Public Key (1.2.840.10045.2.1)
  Asn1OidRsaEncryption* = [
    0x2A'u8, 0x86'u8, 0x48'u8, 0x86'u8, 0xF7'u8, 0x0D'u8, 0x01'u8,
    0x01'u8, 0x01'u8
  ]
    ## Encoded OID for RSA Encryption (1.2.840.113549.1.1.1)
  Asn1True* = [0x01'u8, 0x01'u8, 0xFF'u8]
    ## Encoded boolean ``TRUE``.
  Asn1False* = [0x01'u8, 0x01'u8, 0x00'u8]
    ## Encoded boolean ``FALSE``.
  Asn1Null* = [0x05'u8, 0x00'u8]
    ## Encoded ``NULL`` value.

template toOpenArray*(ab: Asn1Buffer): untyped =
  toOpenArray(ab.buffer, ab.offset, len(ab.buffer) - 1)

template toOpenArray*(ac: Asn1Composite): untyped =
  toOpenArray(ac.buffer, ac.offset, len(ac.buffer) - 1)

template toOpenArray*(af: Asn1Field): untyped =
  toOpenArray(af.buffer, af.offset, af.offset + af.length - 1)

template isEmpty*(ab: Asn1Buffer): bool =
  ab.offset >= len(ab.buffer)

template isEnough*(ab: Asn1Buffer, length: int): bool =
  len(ab.buffer) >= ab.offset + length

proc len*[T: Asn1Buffer|Asn1Composite](abc: T): int {.inline.} =
  len(abc.buffer) - abc.offset

proc len*(field: Asn1Field): int {.inline.} =
  result = field.length

template getPtr*(field: untyped): pointer =
  cast[pointer](unsafeAddr field.buffer[field.offset])

proc extend*[T: Asn1Buffer|Asn1Composite](abc: var T, length: int) {.inline.} =
  ## Extend buffer or composite's internal buffer by ``length`` octets.
  abc.buffer.setLen(len(abc.buffer) + length)

proc code*(tag: Asn1Tag): byte {.inline.} =
  ## Converts Nim ``tag`` enum to ASN.1 tag code.
  case tag:
  of Asn1Tag.NoSupport:
    0x00'u8
  of Asn1Tag.Boolean:
    0x01'u8
  of Asn1Tag.Integer:
    0x02'u8
  of Asn1Tag.BitString:
    0x03'u8
  of Asn1Tag.OctetString:
    0x04'u8
  of Asn1Tag.Null:
    0x05'u8
  of Asn1Tag.Oid:
    0x06'u8
  of Asn1Tag.Sequence:
    0x30'u8
  of Asn1Tag.Context:
    0xA0'u8

proc asn1EncodeLength*(dest: var openarray[byte], length: int64): int =
  ## Encode ASN.1 DER length part of TLV triple and return number of bytes
  ## (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``length`` value, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  if length < 0x80:
    if len(dest) >= 1:
      dest[0] = cast[byte](length)
      result = 1
  else:
    result = 0
    var z = length
    while z != 0:
      inc(result)
      z = z shr 8
    if len(dest) >= result + 1:
      dest[0] = cast[byte](0x80 + result)
      var o = 1
      for j in countdown(result - 1, 0):
        dest[o] = cast[byte](length shr (j shl 3))
        inc(o)
    inc(result)

proc asn1EncodeInteger*(dest: var openarray[byte],
                        value: openarray[byte]): int =
  ## Encode big-endian binary representation of integer as ASN.1 DER `INTEGER`
  ## and return number of bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var o = 0
  var lenlen = 0
  for i in 0..<len(value):
    if value[o] != 0x00:
      break
    inc(o)
  if len(value) > 0:
    if o == len(value):
      dec(o)
    if value[o] >= 0x80'u8:
      lenlen = asn1EncodeLength(buffer, len(value) - o + 1)
      result = 1 + lenlen + 1 + (len(value) - o)
    else:
      lenlen = asn1EncodeLength(buffer, len(value) - o)
      result = 1 + lenlen + (len(value) - o)
  else:
    result = 2
  if len(dest) >= result:
    var s = 1
    dest[0] = Asn1Tag.Integer.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    if value[o] >= 0x80'u8:
      dest[1 + lenlen] = 0x00'u8
      s = 2
    if len(value) > 0:
      copyMem(addr dest[s + lenlen], unsafeAddr value[o], len(value) - o)

proc asn1EncodeInteger*[T: SomeUnsignedInt](dest: var openarray[byte],
                                            value: T): int =
  ## Encode Nim's unsigned integer as ASN.1 DER `INTEGER` and return number of
  ## bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  dest.asn1EncodeInteger(value.toBytesBE())

proc asn1EncodeBoolean*(dest: var openarray[byte], value: bool): int =
  ## Encode Nim's boolean as ASN.1 DER `BOOLEAN` and return number of bytes
  ## (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  result = 3
  if len(dest) >= result:
    dest[0] = Asn1Tag.Boolean.code()
    dest[1] = 0x01'u8
    dest[2] = if value: 0xFF'u8 else: 0x00'u8

proc asn1EncodeNull*(dest: var openarray[byte]): int =
  ## Encode ASN.1 DER `NULL` and return number of bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  result = 2
  if len(dest) >= result:
    dest[0] = Asn1Tag.Null.code()
    dest[1] = 0x00'u8

proc asn1EncodeOctetString*(dest: var openarray[byte],
                          value: openarray[byte]): int =
  ## Encode array of bytes as ASN.1 DER `OCTET STRING` and return number of
  ## bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value))
  result = 1 + lenlen + len(value)
  if len(dest) >= result:
    dest[0] = Asn1Tag.OctetString.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    if len(value) > 0:
      copyMem(addr dest[1 + lenlen], unsafeAddr value[0], len(value))

proc asn1EncodeBitString*(dest: var openarray[byte],
                          value: openarray[byte], bits = 0): int =
  ## Encode array of bytes as ASN.1 DER `BIT STRING` and return number of bytes
  ## (octets) used.
  ##
  ## ``bits`` number of used bits in ``value``. If ``bits == 0``, all the bits
  ## from ``value`` are used, if ``bits != 0`` only number of ``bits`` will be
  ## used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value) + 1)
  var lbits = 0
  if bits != 0:
    lbits = len(value) shl 3 - bits
  result = 1 + lenlen + 1 + len(value)
  if len(dest) >= result:
    dest[0] = Asn1Tag.BitString.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    dest[1 + lenlen] = cast[byte](lbits)
    if len(value) > 0:
      copyMem(addr dest[2 + lenlen], unsafeAddr value[0], len(value))

proc asn1EncodeTag[T: SomeUnsignedInt](dest: var openarray[byte],
                                       value: T): int =
  var v = value
  if value <= cast[T](0x7F):
    if len(dest) >= 1:
      dest[0] = cast[byte](value)
    result = 1
  else:
    var s = 0
    while v != 0:
      v = v shr 7
      s += 7
      inc(result)
    if len(dest) >= result:
      var k = 0
      while s != 0:
        s -= 7
        dest[k] = cast[byte](((value shr s) and cast[T](0x7F)) or cast[T](0x80))
        inc(k)
      dest[k - 1] = dest[k - 1] and 0x7F'u8

proc asn1EncodeOid*(dest: var openarray[byte], value: openarray[int]): int =
  ## Encode array of integers ``value`` as ASN.1 DER `OBJECT IDENTIFIER` and
  ## return number of bytes (octets) used.
  ##
  ## OBJECT IDENTIFIER requirements for ``value`` elements:
  ##   * len(value) >= 2
  ##   * value[0] >= 1 and value[0] < 2
  ##   * value[1] >= 1 and value[1] < 39
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  result = 1
  doAssert(len(value) >= 2)
  doAssert(value[0] >= 1 and value[0] < 2)
  doAssert(value[1] >= 1 and value[1] <= 39)
  var oidlen = 1
  for i in 2..<len(value):
    oidlen += asn1EncodeTag(buffer, cast[uint64](value[i]))
  result += asn1EncodeLength(buffer, oidlen)
  result += oidlen
  if len(dest) >= result:
    let last = len(dest) - 1
    var offset = 1
    dest[0] = Asn1Tag.Oid.code()
    offset += asn1EncodeLength(dest.toOpenArray(offset, last), oidlen)
    dest[offset] = cast[byte](value[0] * 40 + value[1])
    offset += 1
    for i in 2..<len(value):
      offset += asn1EncodeTag(dest.toOpenArray(offset, last),
                              cast[uint64](value[i]))

proc asn1EncodeOid*(dest: var openarray[byte], value: openarray[byte]): int =
  ## Encode array of bytes ``value`` as ASN.1 DER `OBJECT IDENTIFIER` and return
  ## number of bytes (octets) used.
  ##
  ## This procedure is useful to encode constant predefined identifiers such
  ## as ``asn1OidSecp256r1``, ``asn1OidRsaEncryption``.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value))
  result = 1 + lenlen + len(value)
  if len(dest) >= result:
    dest[0] = Asn1Tag.Oid.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    copyMem(addr dest[1 + lenlen], unsafeAddr value[0], len(value))

proc asn1EncodeSequence*(dest: var openarray[byte],
                         value: openarray[byte]): int =
  ## Encode ``value`` as ASN.1 DER `SEQUENCE` and return number of bytes
  ## (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value))
  result = 1 + lenlen + len(value)
  if len(dest) >= result:
    dest[0] = Asn1Tag.Sequence.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    copyMem(addr dest[1 + lenlen], unsafeAddr value[0], len(value))

proc asn1EncodeComposite*(dest: var openarray[byte],
                          value: Asn1Composite): int =
  ## Encode composite value and return number of bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value.buffer))
  result = 1 + lenlen + len(value.buffer)
  if len(dest) >= result:
    dest[0] = value.tag.code()
    copyMem(addr dest[1], addr buffer[0], lenlen)
    copyMem(addr dest[1 + lenlen], unsafeAddr value.buffer[0],
            len(value.buffer))

proc asn1EncodeContextTag*(dest: var openarray[byte], value: openarray[byte],
                           tag: int): int =
  ## Encode ASN.1 DER `CONTEXT SPECIFIC TAG` ``tag`` for value ``value`` and
  ## return number of bytes (octets) used.
  ##
  ## If length of ``dest`` is less then number of required bytes to encode
  ## ``value``, then result of encoding will not be stored in ``dest``
  ## but number of bytes (octets) required will be returned.
  var buffer: array[16, byte]
  var lenlen = asn1EncodeLength(buffer, len(value))
  result = 1 + lenlen + len(value)
  if len(dest) >= result:
    dest[0] = 0xA0'u8 or (cast[byte](tag) and 0x0F)
    copyMem(addr dest[1], addr buffer[0], lenlen)
    copyMem(addr dest[1 + lenlen], unsafeAddr value[0], len(value))

proc getLength(ab: var Asn1Buffer, length: var uint64): Asn1Status =
  ## Decode length part of ASN.1 TLV triplet.
  result = Asn1Status.Incomplete
  if not ab.isEmpty():
    let b = ab.buffer[ab.offset]
    if (b and 0x80'u8) == 0x00'u8:
      length = cast[uint64](b)
      ab.offset += 1
      result = Asn1Status.Success
      return
    if b == 0x80'u8:
      length = 0'u64
      result = Asn1Status.Indefinite
      return
    if b == 0xFF'u8:
      length = 0'u64
      result = Asn1Status.Incorrect
      return
    let octets = cast[uint64](b and 0x7F'u8)
    if octets > 8'u64:
      length = 0'u64
      result = Asn1Status.Overflow
      return
    length = 0'u64
    if ab.isEnough(int(octets)):
      for i in 0..<int(octets):
        length = (length shl 8) or cast[uint64](ab.buffer[ab.offset + i + 1])
      ab.offset = ab.offset + int(octets) + 1
      result = Asn1Status.Success

proc getTag(ab: var Asn1Buffer, tag: var int,
            klass: var Asn1Class): Asn1Status =
  ## Decode tag part of ASN.1 TLV triplet.
  result = Asn1Status.Incomplete
  if not ab.isEmpty():
    let b = ab.buffer[ab.offset]
    var c = int((b and 0xC0'u8) shr 6)
    if c >= 0 and c < 4:
      klass = cast[Asn1Class](c)
    else:
      return Asn1Status.Incorrect
    tag = int(b and 0x3F)
    ab.offset += 1
    result = Asn1Status.Success

proc read*(ab: var Asn1Buffer, field: var Asn1Field): Asn1Status =
  ## Decode value part of ASN.1 TLV triplet.
  var
    tag, ttag, offset: int
    length, tlength: uint64
    klass: Asn1Class
    inclass: bool

  inclass = false
  while true:
    offset = ab.offset
    result = ab.getTag(tag, klass)
    if result != Asn1Status.Success:
      break

    if klass == Asn1Class.ContextSpecific:
      if inclass:
        result = Asn1Status.Incorrect
        break
      inclass = true
      ttag = tag
      result = ab.getLength(tlength)
      if result != Asn1Status.Success:
        break

    elif klass == Asn1Class.Universal:
      result = ab.getLength(length)
      if result != Asn1Status.Success:
        break

      if inclass:
        if length >= tlength:
          result = Asn1Status.Incorrect
          break

      if cast[byte](tag) == Asn1Tag.Boolean.code():
        # BOOLEAN
        if length != 1:
          result = Asn1Status.Incorrect
          break
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        let b = ab.buffer[ab.offset]
        if b != 0xFF'u8 and b != 0x00'u8:
          result = Asn1Status.Incorrect
          break
        field = Asn1Field(kind: Asn1Tag.Boolean, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: 1)
        shallowCopy(field.buffer, ab.buffer)
        field.vbool = (b == 0xFF'u8)
        ab.offset += 1
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.Integer.code():
        # INTEGER
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        if ab.buffer[ab.offset] == 0x00'u8:
          length -= 1
          ab.offset += 1
        field = Asn1Field(kind: Asn1Tag.Integer, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: cast[int](length))
        shallowCopy(field.buffer, ab.buffer)
        if length <= 8:
          for i in 0..<int(length):
            field.vint = (field.vint shl 8) or
                         cast[uint64](ab.buffer[ab.offset + i])
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.BitString.code():
        # BIT STRING
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        field = Asn1Field(kind: Asn1Tag.BitString, klass: klass,
                          index: ttag, offset: cast[int](ab.offset + 1),
                          length: cast[int](length - 1))
        shallowCopy(field.buffer, ab.buffer)
        field.ubits = cast[int](((length - 1) shl 3) - ab.buffer[ab.offset])
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.OctetString.code():
        # OCT STRING
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        field = Asn1Field(kind: Asn1Tag.OctetString, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: cast[int](length))
        shallowCopy(field.buffer, ab.buffer)
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.Null.code():
        # NULL
        if length != 0:
          result = Asn1Status.Incorrect
          break
        field = Asn1Field(kind: Asn1Tag.Null, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: 0)
        shallowCopy(field.buffer, ab.buffer)
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.Oid.code():
        # OID
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        field = Asn1Field(kind: Asn1Tag.Oid, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: cast[int](length))
        shallowCopy(field.buffer, ab.buffer)
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      elif cast[byte](tag) == Asn1Tag.Sequence.code():
        # SEQUENCE
        if not ab.isEnough(cast[int](length)):
          result = Asn1Status.Incomplete
          break
        field = Asn1Field(kind: Asn1Tag.Sequence, klass: klass,
                          index: ttag, offset: cast[int](ab.offset),
                          length: cast[int](length))
        shallowCopy(field.buffer, ab.buffer)
        ab.offset += cast[int](length)
        result = Asn1Status.Success
        break
      else:
        result = Asn1Status.NoSupport
        break
      inclass = false
      ttag = 0
    else:
      result = Asn1Status.NoSupport
      break

proc getBuffer*(field: Asn1Field): Asn1Buffer =
  ## Return ``field`` as Asn1Buffer to enter composite types.
  shallowCopy(result.buffer, field.buffer)
  result.offset = field.offset
  result.length = field.length

proc `==`*(field: Asn1Field, data: openarray[byte]): bool =
  ## Compares field ``field`` data with ``data`` and returns ``true`` if both
  ## buffers are equal.
  let length = len(field.buffer)
  if length > 0:
    if field.length == len(data):
      result = equalMem(unsafeAddr field.buffer[field.offset],
                        unsafeAddr data[0], field.length)

proc init*(t: typedesc[Asn1Buffer], data: openarray[byte]): Asn1Buffer =
  ## Initialize ``Asn1Buffer`` from array of bytes ``data``.
  result.buffer = @data

proc init*(t: typedesc[Asn1Buffer], data: string): Asn1Buffer =
  ## Initialize ``Asn1Buffer`` from hexadecimal string ``data``.
  result.buffer = fromHex(data)

proc init*(t: typedesc[Asn1Buffer]): Asn1Buffer =
  ## Initialize empty ``Asn1Buffer``.
  result.buffer = newSeq[byte]()

proc init*(t: typedesc[Asn1Composite], tag: Asn1Tag): Asn1Composite =
  ## Initialize ``Asn1Composite`` with tag ``tag``.
  result.tag = tag
  result.buffer = newSeq[byte]()

proc init*(t: typedesc[Asn1Composite], idx: int): Asn1Composite =
  ## Initialize ``Asn1Composite`` with tag context-specific id ``id``.
  result.tag = Asn1Tag.Context
  result.idx = idx
  result.buffer = newSeq[byte]()

proc `$`*(buffer: Asn1Buffer): string =
  ## Return string representation of ``buffer``.
  result = toHex(buffer.toOpenArray())

proc `$`*(field: Asn1Field): string =
  ## Return string representation of ``field``.
  result = "["
  result.add($field.kind)
  result.add("]")
  if field.kind == Asn1Tag.NoSupport:
    result.add(" ")
    result.add(toHex(field.toOpenArray()))
  elif field.kind == Asn1Tag.Boolean:
    result.add(" ")
    result.add($field.vbool)
  elif field.kind == Asn1Tag.Integer:
    result.add(" ")
    if field.length <= 8:
      result.add($field.vint)
    else:
      result.add(toHex(field.toOpenArray()))
  elif field.kind == Asn1Tag.BitString:
    result.add(" ")
    result.add("(")
    result.add($field.ubits)
    result.add(" bits) ")
    result.add(toHex(field.toOpenArray()))
  elif field.kind == Asn1Tag.OctetString:
    result.add(" ")
    result.add(toHex(field.toOpenArray()))
  elif field.kind == Asn1Tag.Null:
    result.add(" NULL")
  elif field.kind == Asn1Tag.Oid:
    result.add(" ")
    result.add(toHex(field.toOpenArray()))
  elif field.kind == Asn1Tag.Sequence:
    result.add(" ")
    result.add(toHex(field.toOpenArray()))

proc write*[T: Asn1Buffer|Asn1Composite](abc: var T, tag: Asn1Tag) =
  ## Write empty value to buffer or composite with ``tag``.
  ##
  ## This procedure must be used to write `NULL`, `0` or empty `BIT STRING`,
  ## `OCTET STRING` types.
  doAssert(tag in {Asn1Tag.Null, Asn1Tag.Integer, Asn1Tag.BitString,
                 Asn1Tag.OctetString})
  var length: int
  if tag == Asn1Tag.Null:
    length = asn1EncodeNull(abc.toOpenArray())
    abc.extend(length)
    discard asn1EncodeNull(abc.toOpenArray())
  elif tag == Asn1Tag.Integer:
    length = asn1EncodeInteger(abc.toOpenArray(), 0'u64)
    abc.extend(length)
    discard asn1EncodeInteger(abc.toOpenArray(), 0'u64)
  elif tag == Asn1Tag.BitString:
    var tmp: array[1, byte]
    length = asn1EncodeBitString(abc.toOpenArray(), tmp.toOpenArray(0, -1))
    abc.extend(length)
    discard asn1EncodeBitString(abc.toOpenArray(), tmp.toOpenArray(0, -1))
  elif tag == Asn1Tag.OctetString:
    var tmp: array[1, byte]
    length = asn1EncodeOctetString(abc.toOpenArray(), tmp.toOpenArray(0, -1))
    abc.extend(length)
    discard asn1EncodeOctetString(abc.toOpenArray(), tmp.toOpenArray(0, -1))
  abc.offset += length

proc write*[T: Asn1Buffer|Asn1Composite](abc: var T, value: uint64) =
  ## Write uint64 ``value`` to buffer or composite as ASN.1 `INTEGER`.
  let length = asn1EncodeInteger(abc.toOpenArray(), value)
  abc.extend(length)
  discard asn1EncodeInteger(abc.toOpenArray(), value)
  abc.offset += length

proc write*[T: Asn1Buffer|Asn1Composite](abc: var T, value: bool) =
  ## Write bool ``value`` to buffer or composite as ASN.1 `BOOLEAN`.
  let length = asn1EncodeBoolean(abc.toOpenArray(), value)
  abc.extend(length)
  discard asn1EncodeBoolean(abc.toOpenArray(), value)
  abc.offset += length

proc write*[T: Asn1Buffer|Asn1Composite](abc: var T, tag: Asn1Tag,
                                         value: openarray[byte], bits = 0) =
  ## Write array ``value`` using ``tag``.
  ##
  ## This procedure is used to write ASN.1 `INTEGER`, `OCTET STRING`,
  ## `BIT STRING` or `OBJECT IDENTIFIER`.
  ##
  ## For `BIT STRING` you can use ``bits`` argument to specify number of used
  ## bits.
  doAssert(tag in {Asn1Tag.Integer, Asn1Tag.OctetString, Asn1Tag.BitString,
                 Asn1Tag.Oid})
  var length: int
  if tag == Asn1Tag.Integer:
    length = asn1EncodeInteger(abc.toOpenArray(), value)
    abc.extend(length)
    discard asn1EncodeInteger(abc.toOpenArray(), value)
  elif tag == Asn1Tag.OctetString:
    length = asn1EncodeOctetString(abc.toOpenArray(), value)
    abc.extend(length)
    discard asn1EncodeOctetString(abc.toOpenArray(), value)
  elif tag == Asn1Tag.BitString:
    length = asn1EncodeBitString(abc.toOpenArray(), value, bits)
    abc.extend(length)
    discard asn1EncodeBitString(abc.toOpenArray(), value, bits)
  elif tag == Asn1Tag.Oid:
    length = asn1EncodeOid(abc.toOpenArray(), value)
    abc.extend(length)
    discard asn1EncodeOid(abc.toOpenArray(), value)
  abc.offset += length

proc write*[T: Asn1Buffer|Asn1Composite](abc: var T, value: Asn1Composite) =
  doAssert(len(value) > 0, "Composite value not finished")
  var length: int
  if value.tag == Asn1Tag.Sequence:
    length = asn1EncodeSequence(abc.toOpenArray(), value.buffer)
    abc.extend(length)
    discard asn1EncodeSequence(abc.toOpenArray(), value.buffer)
  elif value.tag == Asn1Tag.BitString:
    length = asn1EncodeBitString(abc.toOpenArray(), value.buffer)
    abc.extend(length)
    discard asn1EncodeBitString(abc.toOpenArray(), value.buffer)
  elif value.tag == Asn1Tag.Context:
    length = asn1EncodeContextTag(abc.toOpenArray(), value.buffer, value.idx)
    abc.extend(length)
    discard asn1EncodeContextTag(abc.toOpenArray(), value.buffer, value.idx)
  abc.offset += length

proc finish*[T: Asn1Buffer|Asn1Composite](abc: var T) {.inline.} =
  ## Finishes buffer or composite and prepares it for writing.
  abc.offset = 0
