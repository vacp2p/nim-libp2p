## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements MultiBase.
##
## TODO:
## 1. base32z
##

{.push raises: [Defect].}

import tables
import stew/[base32, base58, base64, results]

type
  MultibaseStatus* {.pure.} = enum
    Error, Success, Overrun, Incorrect, BadCodec, NotSupported

  MultiBase* = object

  MBCodeSize = proc(length: int): int {.nimcall, gcsafe, noSideEffect, raises: [Defect].}

  MBCodec = object
    code: char
    name: string
    encr: proc(inbytes: openarray[byte],
               outbytes: var openarray[char],
               outlen: var int): MultibaseStatus {.nimcall, gcsafe, noSideEffect, raises: [Defect].}
    decr: proc(inbytes: openarray[char],
               outbytes: var openarray[byte],
               outlen: var int): MultibaseStatus {.nimcall, gcsafe, noSideEffect, raises: [Defect].}
    encl: MBCodeSize
    decl: MBCodeSize

proc idd(inbytes: openarray[char], outbytes: var openarray[byte],
         outlen: var int): MultibaseStatus =
  let length = len(inbytes)
  if length > len(outbytes):
    outlen = length
    result = MultibaseStatus.Overrun
  else:
    copyMem(addr outbytes[0], unsafeAddr inbytes[0], length)
    outlen = length
    result = MultibaseStatus.Success

proc ide(inbytes: openarray[byte],
         outbytes: var openarray[char],
         outlen: var int): MultibaseStatus =
  let length = len(inbytes)
  if length > len(outbytes):
    outlen = length
    result = MultibaseStatus.Overrun
  else:
    copyMem(addr outbytes[0], unsafeAddr inbytes[0], length)
    outlen = length
    result = MultibaseStatus.Success

proc idel(length: int): int = length
proc iddl(length: int): int = length

proc b16d(inbytes: openarray[char],
          outbytes: var openarray[byte],
          outlen: var int): MultibaseStatus =
  discard

proc b16e(inbytes: openarray[byte],
          outbytes: var openarray[char],
          outlen: var int): MultibaseStatus =
  discard

proc b16ud(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  discard

proc b16ue(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  discard

proc b16el(length: int): int = length shl 1
proc b16dl(length: int): int = (length + 1) div 2

proc b32ce(r: Base32Status): MultibaseStatus {.inline.} =
  result = MultibaseStatus.Error
  if r == Base32Status.Incorrect:
    result = MultibaseStatus.Incorrect
  elif r == Base32Status.Overrun:
    result = MultibaseStatus.Overrun
  elif r == Base32Status.Success:
    result = MultibaseStatus.Success

proc b58ce(r: Base58Status): MultibaseStatus {.inline.} =
  result = MultibaseStatus.Error
  if r == Base58Status.Incorrect:
    result = MultibaseStatus.Incorrect
  elif r == Base58Status.Overrun:
    result = MultibaseStatus.Overrun
  elif r == Base58Status.Success:
    result = MultibaseStatus.Success

proc b64ce(r: Base64Status): MultibaseStatus {.inline.} =
  result = MultiBaseStatus.Error
  if r == Base64Status.Incorrect:
    result = MultibaseStatus.Incorrect
  elif r == Base64Status.Overrun:
    result = MultiBaseStatus.Overrun
  elif r == Base64Status.Success:
    result = MultibaseStatus.Success

proc b32hd(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32Lower.decode(inbytes, outbytes, outlen))

proc b32he(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32Lower.encode(inbytes, outbytes, outlen))

proc b32hud(inbytes: openarray[char],
            outbytes: var openarray[byte],
            outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32Upper.decode(inbytes, outbytes, outlen))

proc b32hue(inbytes: openarray[byte],
            outbytes: var openarray[char],
            outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32Upper.encode(inbytes, outbytes, outlen))

proc b32hpd(inbytes: openarray[char],
            outbytes: var openarray[byte],
            outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32LowerPad.decode(inbytes, outbytes, outlen))

proc b32hpe(inbytes: openarray[byte],
            outbytes: var openarray[char],
            outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32LowerPad.encode(inbytes, outbytes, outlen))

proc b32hpud(inbytes: openarray[char],
             outbytes: var openarray[byte],
             outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32UpperPad.decode(inbytes, outbytes, outlen))

proc b32hpue(inbytes: openarray[byte],
             outbytes: var openarray[char],
             outlen: var int): MultibaseStatus =
  result = b32ce(HexBase32UpperPad.encode(inbytes, outbytes, outlen))

proc b32d(inbytes: openarray[char],
          outbytes: var openarray[byte],
          outlen: var int): MultibaseStatus =
  result = b32ce(Base32Lower.decode(inbytes, outbytes, outlen))

proc b32e(inbytes: openarray[byte],
          outbytes: var openarray[char],
          outlen: var int): MultibaseStatus =
  result = b32ce(Base32Lower.encode(inbytes, outbytes, outlen))

proc b32ud(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b32ce(Base32Upper.decode(inbytes, outbytes, outlen))

proc b32ue(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b32ce(Base32Upper.encode(inbytes, outbytes, outlen))

proc b32pd(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b32ce(Base32LowerPad.decode(inbytes, outbytes, outlen))

proc b32pe(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b32ce(Base32LowerPad.encode(inbytes, outbytes, outlen))

proc b32pud(inbytes: openarray[char],
            outbytes: var openarray[byte],
            outlen: var int): MultibaseStatus =
  result = b32ce(Base32UpperPad.decode(inbytes, outbytes, outlen))

proc b32pue(inbytes: openarray[byte],
            outbytes: var openarray[char],
            outlen: var int): MultibaseStatus =
  result = b32ce(Base32UpperPad.encode(inbytes, outbytes, outlen))

proc b32el(length: int): int = Base32Lower.encodedLength(length)
proc b32dl(length: int): int = Base32Lower.decodedLength(length)
proc b32pel(length: int): int = Base32LowerPad.encodedLength(length)
proc b32pdl(length: int): int = Base32LowerPad.decodedLength(length)

proc b58fd(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b58ce(FLCBase58.decode(inbytes, outbytes, outlen))

proc b58fe(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b58ce(FLCBase58.encode(inbytes, outbytes, outlen))

proc b58bd(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b58ce(BTCBase58.decode(inbytes, outbytes, outlen))

proc b58be(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b58ce(BTCBase58.encode(inbytes, outbytes, outlen))

proc b58el(length: int): int = Base58.encodedLength(length)
proc b58dl(length: int): int = Base58.decodedLength(length)

proc b64el(length: int): int = Base64.encodedLength(length)
proc b64dl(length: int): int = Base64.decodedLength(length)
proc b64pel(length: int): int = Base64Pad.encodedLength(length)
proc b64pdl(length: int): int = Base64Pad.decodedLength(length)

proc b64e(inbytes: openarray[byte],
          outbytes: var openarray[char],
          outlen: var int): MultibaseStatus =
  result = b64ce(Base64.encode(inbytes, outbytes, outlen))

proc b64d(inbytes: openarray[char],
          outbytes: var openarray[byte],
          outlen: var int): MultibaseStatus =
  result = b64ce(Base64.decode(inbytes, outbytes, outlen))

proc b64pe(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b64ce(Base64Pad.encode(inbytes, outbytes, outlen))

proc b64pd(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b64ce(Base64Pad.decode(inbytes, outbytes, outlen))

proc b64ue(inbytes: openarray[byte],
           outbytes: var openarray[char],
           outlen: var int): MultibaseStatus =
  result = b64ce(Base64Url.encode(inbytes, outbytes, outlen))

proc b64ud(inbytes: openarray[char],
           outbytes: var openarray[byte],
           outlen: var int): MultibaseStatus =
  result = b64ce(Base64Url.decode(inbytes, outbytes, outlen))

proc b64upe(inbytes: openarray[byte],
          outbytes: var openarray[char],
          outlen: var int): MultibaseStatus =
  result = b64ce(Base64UrlPad.encode(inbytes, outbytes, outlen))

proc b64upd(inbytes: openarray[char],
            outbytes: var openarray[byte],
            outlen: var int): MultibaseStatus =
  result = b64ce(Base64UrlPad.decode(inbytes, outbytes, outlen))

const
  MultibaseCodecs = [
    MBCodec(name: "identity", code: chr(0x00),
      decr: idd, encr: ide, decl: iddl, encl: idel
    ),
    MBCodec(name: "base1", code: '1'),
    MBCodec(name: "base2", code: '0'),
    MBCodec(name: "base8", code: '7'),
    MBCodec(name: "base10", code: '9'),
    MBCodec(name: "base16", code: 'f',
      decr: b16d, encr: b16e, decl: b16dl, encl: b16el
    ),
    MBCodec(name: "base16upper", code: 'F',
      decr: b16ud, encr: b16ue, decl: b16dl, encl: b16el
    ),
    MBCodec(name: "base32hex", code: 'v',
      decr: b32hd, encr: b32he, decl: b32dl, encl: b32el
    ),
    MBCodec(name: "base32hexupper", code: 'V',
      decr: b32hud, encr: b32hue, decl: b32dl, encl: b32el
    ),
    MBCodec(name: "base32hexpad", code: 't',
      decr: b32hpd, encr: b32hpe, decl: b32pdl, encl: b32pel
    ),
    MBCodec(name: "base32hexpadupper", code: 'T',
      decr: b32hpud, encr: b32hpue, decl: b32pdl, encl: b32pel
    ),
    MBCodec(name: "base32", code: 'b',
      decr: b32d, encr: b32e, decl: b32dl, encl: b32el
    ),
    MBCodec(name: "base32upper", code: 'B',
      decr: b32ud, encr: b32ue, decl: b32dl, encl: b32el
    ),
    MBCodec(name: "base32pad", code: 'c',
      decr: b32pd, encr: b32pe, decl: b32pdl, encl: b32pel
    ),
    MBCodec(name: "base32padupper", code: 'C',
      decr: b32pud, encr: b32pue, decl: b32pdl, encl: b32pel
    ),
    MBCodec(name: "base32z", code: 'h'),
    MBCodec(name: "base58flickr", code: 'Z',
      decr: b58fd, encr: b58fe, decl: b58dl, encl: b58el
    ),
    MBCodec(name: "base58btc", code: 'z',
      decr: b58bd, encr: b58be, decl: b58dl, encl: b58el
    ),
    MBCodec(name: "base64", code: 'm',
      decr: b64d, encr: b64e, decl: b64dl, encl: b64el
    ),
    MBCodec(name: "base64pad", code: 'M',
      decr: b64pd, encr: b64pe, decl: b64pdl, encl: b64pel
    ),
    MBCodec(name: "base64url", code: 'u',
      decr: b64ud, encr: b64ue, decl: b64dl, encl: b64el
    ),
    MBCodec(name: "base64urlpad", code: 'U',
      decr: b64upd, encr: b64upe, decl: b64pdl, encl: b64pel
    )
  ]

proc initMultiBaseCodeTable(): Table[char, MBCodec] {.compileTime.} =
  for item in MultibaseCodecs:
    result[item.code] = item

proc initMultiBaseNameTable(): Table[string, MBCodec] {.compileTime.} =
  for item in MultibaseCodecs:
    result[item.name] = item

const
  CodeMultibases = initMultiBaseCodeTable()
  NameMultibases = initMultiBaseNameTable()

proc encodedLength*(mbtype: typedesc[MultiBase], encoding: string,
                    length: int): int =
  ## Return estimated size of buffer to store MultiBase encoded value with
  ## encoding ``encoding`` of length ``length``.
  ##
  ## Procedure returns ``-1`` if ``encoding`` scheme is not supported or
  ## not present.
  let mb = NameMultibases.getOrDefault(encoding)
  if len(mb.name) == 0 or isNil(mb.encl):
    result = -1
  else:
    if length == 0:
      result = 1
    else:
      result = mb.encl(length) + 1

proc decodedLength*(mbtype: typedesc[MultiBase], encoding: char,
                    length: int): int =
  ## Return estimated size of buffer to store MultiBase decoded value with
  ## encoding character ``encoding`` of length ``length``.
  let mb = CodeMultibases.getOrDefault(encoding)
  if len(mb.name) == 0 or isNil(mb.decl) or length == 0:
    result = -1
  else:
    if length == 1:
      result = 0
    else:
      result = mb.decl(length - 1)

proc encode*(mbtype: typedesc[MultiBase], encoding: string,
             inbytes: openarray[byte], outbytes: var openarray[char],
             outlen: var int): MultibaseStatus =
  ## Encode array ``inbytes`` using MultiBase encoding scheme ``encoding`` and
  ## store encoded value to ``outbytes``.
  ##
  ## If ``encoding`` is not supported ``MultiBaseStatus.NotSupported`` will be
  ## returned.
  ##
  ## If ``encoding`` is not correct string, then ``MultBaseStatus.BadCodec``
  ## will be returned.
  ##
  ## If length of ``outbytes`` is not enough to store encoded result, then
  ## ``MultiBaseStatus.Overrun`` error will be returned and ``outlen`` will be
  ## set to length required.
  ##
  ## On successfull encoding ``MultiBaseStatus.Success`` will be returned and
  ## ``outlen`` will be set to number of encoded octets (bytes).
  let mb = NameMultibases.getOrDefault(encoding)
  if len(mb.name) == 0:
    return MultibaseStatus.BadCodec
  if isNil(mb.encr) or isNil(mb.encl):
    return MultibaseStatus.NotSupported
  if len(outbytes) > 1:
    result = mb.encr(inbytes, outbytes.toOpenArray(1, outbytes.high),
                     outlen)
    if result == MultiBaseStatus.Overrun:
      outlen += 1
    elif result == MultiBaseStatus.Success:
      outlen += 1
      outbytes[0] = mb.code
  else:
    if len(inbytes) == 0 and len(outbytes) == 1:
      result = MultiBaseStatus.Success
      outlen = 1
      outbytes[0] = mb.code
    else:
      result = MultiBaseStatus.Overrun
      outlen = mb.encl(len(inbytes)) + 1

proc decode*(mbtype: typedesc[MultiBase], inbytes: openarray[char],
             outbytes: var openarray[byte], outlen: var int): MultibaseStatus =
  ## Decode array ``inbytes`` using MultiBase encoding and store decoded value
  ## to ``outbytes``.
  ##
  ## If ``inbytes`` is not correct MultiBase string, then
  ## ``MultiBaseStatus.BadCodec`` if first character is wrong, or
  ## ``MultiBaseStatus.Incorrect`` if string has incorrect characters for
  ## such encoding.
  ##
  ## If length of ``outbytes`` is not enough to store decoded result, then
  ## ``MultiBaseStatus.Overrun`` error will be returned and ``outlen`` will be
  ## set to length required.
  ##
  ## On successfull decoding ``MultiBaseStatus.Success`` will be returned and
  ## ``outlen`` will be set to number of encoded octets (bytes).
  let length = len(inbytes)
  if length == 0:
    return MultibaseStatus.Incorrect
  let mb = CodeMultibases.getOrDefault(inbytes[0])
  if len(mb.name) == 0:
    return MultibaseStatus.BadCodec
  if isNil(mb.decr) or isNil(mb.decl):
    return MultibaseStatus.NotSupported
  if length == 1:
    outlen = 0
    result = MultibaseStatus.Success
  else:
    result = mb.decr(inbytes.toOpenArray(1, length - 1), outbytes, outlen)

proc encode*(mbtype: typedesc[MultiBase], encoding: string,
             inbytes: openarray[byte]): Result[string, string] =
  ## Encode array ``inbytes`` using MultiBase encoding scheme ``encoding`` and
  ## return encoded string.
  let length = len(inbytes)
  let mb = NameMultibases.getOrDefault(encoding)
  if len(mb.name) == 0:
    return err("multibase: Encoding scheme is incorrect!")
  if isNil(mb.encr) or isNil(mb.encl):
    return err("multibase: Encoding scheme is not supported!")
  var buffer: string
  if length > 0:
    buffer = newString(mb.encl(length) + 1)
    var outlen = 0
    let res = mb.encr(inbytes, buffer.toOpenArray(1, buffer.high), outlen)
    if res != MultiBaseStatus.Success:
      return err("multibase: Encoding error [" & $res & "]")
    buffer.setLen(outlen + 1)
    buffer[0] = mb.code
  else:
    buffer = newString(1)
    buffer[0] = mb.code
  ok(buffer)

proc decode*(mbtype: typedesc[MultiBase], inbytes: openarray[char]): Result[seq[byte], string] =
  ## Decode MultiBase encoded array ``inbytes`` and return decoded sequence of
  ## bytes.
  let length = len(inbytes)
  if length == 0:
    return err("multibase: Could not decode zero-length string")
  let mb = CodeMultibases.getOrDefault(inbytes[0])
  if len(mb.name) == 0:
    return err("multibase: MultiBase scheme is incorrect!")
  if isNil(mb.decr) or isNil(mb.decl):
    return err("multibase: MultiBase scheme is not supported!")
  if length == 1:
    let empty: seq[byte] = @[]
    ok(empty) # empty
  else:
    var buffer = newSeq[byte](mb.decl(length - 1))
    var outlen = 0
    let res = mb.decr(inbytes.toOpenArray(1, length - 1),
                      buffer, outlen)
    if res != MultiBaseStatus.Success:
      err("multibase: Decoding error [" & $res & "]")
    else:
      buffer.setLen(outlen)
      ok(buffer)
