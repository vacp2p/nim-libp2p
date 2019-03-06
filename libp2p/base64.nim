## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements BASE64 encoding and decoding procedures.

type
  Base64Status* {.pure.} = enum
    Error,
    Success,
    Incorrect,
    Overrun

  Base64Alphabet* = object
    decode*: array[128, int8]
    encode*: array[64, uint8]

  Base64* = object
    ## Type to use RFC4648 alphabet without padding
  Base64Pad* = object
    ## Type to use RFC4648 alphabet with padding
  Base64Url* = object
    ## Type to use RFC4648 URL alphabet without padding
  Base64UrlPad* = object
    ## Type to use RFC4648 URL alphabet with padding

  Base64PadTypes* = Base64Pad | Base64UrlPad
    ## All types with padding support
  Base64NoPadTypes* = Base64 | Base64Url
    ## All types without padding support
  Base64Types* = Base64 | Base64Pad | Base64Url | Base64UrlPad
    ## All types

  Base64Error* = object of Exception
    ## Base64 specific exception type

proc newAlphabet64*(s: string): Base64Alphabet =
  doAssert(len(s) == 64)
  for i in 0..<len(s):
    result.encode[i] = cast[uint8](s[i])
  for i in 0..<len(result.decode):
    result.decode[i] = -1
  for i in 0..<len(result.encode):
    result.decode[int(result.encode[i])] = int8(i)

const
  B64Alphabet* = newAlphabet64("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef" &
                               "ghijklmnopqrstuvwxyz0123456789+/")
  B64UrlAlphabet* = newAlphabet64("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef" &
                                  "ghijklmnopqrstuvwxyz0123456789-_")

proc encodedLength*(btype: typedesc[Base64Types],
                    length: int): int {.inline.} =
  ## Return estimated length of BASE64 encoded value for plain length
  ## ``length``.
  result = (((length + 2) div 3) * 4) + 1

proc decodedLength*(btype: typedesc[Base64Types],
                    length: int): int {.inline.} =
  ## Return estimated length of decoded value of BASE64 encoded value of length
  ## ``length``.
  when (btype is Base64Pad) or (btype is Base64UrlPad):
    result = ((length + 3 - 1) div 3) * 4
  elif (btype is Base64) or (btype is Base64Url):
    result = (length * 4 + 3 - 1) div 3

proc encode*(btype: typedesc[Base64Types], inbytes: openarray[byte],
             outstr: var openarray[char], outlen: var int): Base64Status =
  ## Encode array of bytes ``inbytes`` using BASE64 encoding and store
  ## result to ``outstr``.
  ##
  ## On success ``Base64Status.Success`` will be returned and ``outlen`` will
  ## be set to number of characters stored inside of ``outstr``.
  ##
  ## If length of ``outstr`` is not enough then ``Base64Status.Overrun`` will
  ## be returned and ``outlen`` will be set to number of characters required.
  when (btype is Base64) or (btype is Base64Pad):
    const alphabet = B64Alphabet
  elif (btype is Base64Url) or (btype is Base64UrlPad):
    const alphabet = B64UrlAlphabet

  let length = len(inbytes)
  if len(outstr) < btype.encodedLength(length):
    outlen = btype.encodedLength(length)
    result = Base64Status.Overrun
  else:
    var offset = 0
    var i = 0
    while i < (length - 2):
      outstr[offset] = chr(alphabet.encode[(inbytes[i] shr 2) and 0x3F'u8])
      inc(offset)
      outstr[offset] = chr(alphabet.encode[((inbytes[i] and 0x03) shl 4) or
                                           ((inbytes[i + 1] and 0xF0) shr 4)])
      inc(offset)
      outstr[offset] = chr(alphabet.encode[((inbytes[i + 1] and 0x0F) shl 2) or
                                           ((inbytes[i + 2] and 0xC0) shr 6)])
      inc(offset)
      outstr[offset] = chr(alphabet.encode[inbytes[i + 2] and 0x3F])
      inc(offset)
      i += 3

    if i < length:
      outstr[offset] = chr(alphabet.encode[(inbytes[i] shr 2) and 0x3F])
      inc(offset)
      if i == length - 1:
        outstr[offset] = chr(alphabet.encode[(inbytes[i] and 0x03) shl 4])
        inc(offset)
        when (btype is Base64Pad) or (btype is Base64UrlPad):
          outstr[offset] = '='
          inc(offset)
      else:
        outstr[offset] = chr(alphabet.encode[((inbytes[i] and 0x03) shl 4) or
                                             ((inbytes[i + 1] and 0xF0) shr 4)])
        inc(offset)
        outstr[offset] = chr(alphabet.encode[(inbytes[i + 1] and 0x0F) shl 2])
        inc(offset)

      when (btype is Base64Pad) or (btype is Base64UrlPad):
        outstr[offset] = '='
        inc(offset)

    outlen = offset
    result = Base64Status.Success

proc encode*(btype: typedesc[Base64Types],
             inbytes: openarray[byte]): string {.inline.} =
  ## Encode array of bytes ``inbytes`` using BASE64 encoding and return
  ## encoded string.
  var size = btype.encodedLength(len(inbytes))
  result = newString(size)
  if btype.encode(inbytes, result.toOpenArray(0, size - 1),
                  size) == Base64Status.Success:
    result.setLen(size)
  else:
    result = ""

proc decode*[T: byte|char](btype: typedesc[Base64Types], instr: openarray[T],
             outbytes: var openarray[byte], outlen: var int): Base64Status =
  ## Decode BASE64 string and store array of bytes to ``outbytes``. On success
  ## ``Base64Status.Success`` will be returned and ``outlen`` will be set
  ## to number of bytes stored.
  ##
  ## Length of ``outbytes`` must be equal or more then ``len(instr) + 4``.
  ##
  ## If ``instr`` has characters which are not part of BASE64 alphabet, then
  ## ``Base64Status.Incorrect`` will be returned and ``outlen`` will be set to
  ## ``0``.
  ##
  ## If length of ``outbytes`` is not enough to store decoded bytes, then
  ## ``Base64Status.Overrun`` will be returned and ``outlen`` will be set to
  ## number of bytes required.
  when (btype is Base64) or (btype is Base64Pad):
    const alphabet = B64Alphabet
  elif (btype is Base64Url) or (btype is Base64UrlPad):
    const alphabet = B64UrlAlphabet

  if len(instr) == 0:
    outlen = 0
    return Base64Status.Success

  let length = btype.decodedLength(len(instr))
  if length > len(outbytes):
    outlen = length
    return Base64Status.Overrun

  var inlen = len(instr)
  when (btype is Base64PadTypes):
    for i in countdown(inlen - 1, 0):
      if instr[i] != '=':
        break
      dec(inlen)

  let reminder = inlen mod 4
  let limit = inlen - reminder
  var buffer: array[4, byte]
  var i, k: int
  while i < limit:
    for j in 0..<4:
      if (cast[byte](instr[i + j]) and 0x80'u8) != 0:
        outlen = 0
        zeroMem(addr outbytes[0], i + 3)
        return Base64Status.Incorrect
      let ch = alphabet.decode[cast[int8](instr[i + j])]
      if ch == -1:
        outlen = 0
        zeroMem(addr outbytes[0], i + 3)
        return Base64Status.Incorrect
      buffer[j] = cast[byte](ch)
    outbytes[k] = cast[byte]((buffer[0] shl 2) or (buffer[1] shr 4))
    inc(k)
    outbytes[k] = cast[byte]((buffer[1] shl 4) or (buffer[2] shr 2))
    inc(k)
    outbytes[k] = cast[byte]((buffer[2] shl 6) or buffer[3])
    inc(k)
    i += 4

  if reminder > 0:
    if reminder == 1:
      outlen = 0
      return Base64Status.Incorrect

    for j in 0..<reminder:
      if (cast[byte](instr[i + j]) and 0x80'u8) != 0:
        outlen = 0
        return Base64Status.Incorrect
      let ch = alphabet.decode[cast[int8](instr[i + j])]
      if ch == -1:
        outlen = 0
        return Base64Status.Incorrect
      buffer[j] = cast[byte](ch)

    if reminder > 1:
      outbytes[k] = cast[byte]((buffer[0] shl 2) or (buffer[1] shr 4))
      inc(k)
    if reminder > 2:
      outbytes[k] = cast[byte]((buffer[1] shl 4) or (buffer[2] shr 2))
      inc(k)

  outlen = k
  result = Base64Status.Success

proc decode*[T: byte|char](btype: typedesc[Base64Types],
                           instr: openarray[T]): seq[byte] =
  ## Decode BASE64 string ``instr`` and return sequence of bytes as result.
  if len(instr) == 0:
    result = newSeq[byte]()
  else:
    var length = 0
    result = newSeq[byte](btype.decodedLength(len(instr)))
    if btype.decode(instr, result, length) == Base64Status.Success:
      result.setLen(length)
    else:
      raise newException(Base64Error, "Incorrect base64 string")
