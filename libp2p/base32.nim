## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements BASE32 encoding and decoding procedures.
## This module supports RFC4648's BASE32.

type
  Base32Status* {.pure.} = enum
    Error,
    Success,
    Incorrect,
    Overrun

  Base32Alphabet* = object
    decode*: array[128, int8]
    encode*: array[32, uint8]

  Base32Upper* = object
    ## Type to use RFC4868 alphabet in uppercase without padding
  Base32Lower* = object
    ## Type to use RFC4868 alphabet in lowercase without padding
  Base32UpperPad* = object
    ## Type to use RFC4868 alphabet in uppercase with padding
  Base32LowerPad* = object
    ## Type to use RFC4868 alphabet in lowercase with padding
  HexBase32Upper* = object
    ## Type to use RFC4868-HEX alphabet in uppercase without padding
  HexBase32Lower* = object
    ## Type to use RFC4868-HEX alphabet in lowercase without padding
  HexBase32UpperPad* = object
    ## Type to use RFC4868-HEX alphabet in uppercase with padding
  HexBase32LowerPad* = object
    ## Type to use RFC4868-HEX alphabet in lowercase with padding
  Base32* = Base32Upper
    ## By default we are using RFC4868 alphabet in uppercase without padding
  Base32PadTypes* = Base32UpperPad | Base32LowerPad |
                    HexBase32UpperPad | HexBase32LowerPad
    ## All types with padding support
  Base32NoPadTypes* = Base32Upper | Base32Lower | HexBase32Upper |
                      HexBase32Lower
    ## All types without padding
  Base32Types* = Base32NoPadTypes | Base32PadTypes
    ## Supported types

  Base32Error* = object of Exception
    ## Base32 specific exception type

proc newAlphabet32*(s: string): Base32Alphabet =
  doAssert(len(s) == 32)
  for i in 0..<len(s):
    result.encode[i] = cast[uint8](s[i])
  for i in 0..<len(result.decode):
    result.decode[i] = -1
  for i in 0..<len(result.encode):
    result.decode[int(result.encode[i])] = int8(i)

const
  RFCUpperCaseAlphabet* = newAlphabet32("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
  RFCLowerCaseAlphabet* = newAlphabet32("abcdefghijklmnopqrstuvwxyz234567")
  HEXUpperCaseAlphabet* = newAlphabet32("0123456789ABCDEFGHIJKLMNOPQRSTUV")
  HEXLowerCaseAlphabet* = newAlphabet32("0123456789abcdefghijklmnopqrstuv")

proc encodedLength*(btype: typedesc[Base32Types], length: int): int =
  ## Return length of BASE32 encoded value for plain length ``length``.
  let reminder = length mod 5
  when btype is Base32NoPadTypes:
    result = ((length div 5) * 8) + (((reminder * 8) + 4) div 5)
  else:
    result = ((length div 5) * 8)
    if reminder != 0:
      result += 8

proc decodedLength*(btype: typedesc[Base32Types], length: int): int =
  ## Return length of decoded value of BASE32 encoded value of length
  ## ``length``.
  let reminder = length mod 8
  result = (length div 8) * 5 + ((reminder * 5) div 8)

proc convert5to8(inbytes: openarray[byte], outbytes: var openarray[char],
                 length: int): int {.inline.} =
  if length >= 1:
    outbytes[0] = chr(inbytes[0] shr 3)
    outbytes[1] = chr((inbytes[0] and 7'u8) shl 2)
    result = 2
  if length >= 2:
    outbytes[1] = chr(cast[byte](outbytes[1]) or cast[byte](inbytes[1] shr 6))
    outbytes[2] = chr((inbytes[1] shr 1) and 31'u8)
    outbytes[3] = chr((inbytes[1] and 1'u8) shl 4)
    result = 4
  if length >= 3:
    outbytes[3] = chr(cast[byte](outbytes[3]) or (inbytes[2] shr 4))
    outbytes[4] = chr((inbytes[2] and 15'u8) shl 1)
    result = 5
  if length >= 4:
    outbytes[4] = chr(cast[byte](outbytes[4]) or (inbytes[3] shr 7))
    outbytes[5] = chr((inbytes[3] shr 2) and 31'u8)
    outbytes[6] = chr((inbytes[3] and 3'u8) shl 3)
    result = 7
  if length >= 5:
    outbytes[6] = chr(cast[byte](outbytes[6]) or (inbytes[4] shr 5))
    outbytes[7] = chr(inbytes[4] and 31'u8)
    result = 8

proc convert8to5(inbytes: openarray[byte], outbytes: var openarray[byte],
                 length: int): int {.inline.} =
  if length >= 2:
    outbytes[0] = inbytes[0] shl 3
    outbytes[0] = outbytes[0] or (inbytes[1] shr 2)
    result = 1
  if length >= 4:
    outbytes[1] = (inbytes[1] and 3'u8) shl 6
    outbytes[1] = outbytes[1] or (inbytes[2] shl 1)
    outbytes[1] = outbytes[1] or (inbytes[3] shr 4)
    result = 2
  if length >= 5:
    outbytes[2] = (inbytes[3] and 15'u8) shl 4
    outbytes[2] = outbytes[2] or (inbytes[4] shr 1)
    result = 3
  if length >= 7:
    outbytes[3] = (inbytes[4] and 1'u8) shl 7
    outbytes[3] = outbytes[3] or (inbytes[5] shl 2)
    outbytes[3] = outbytes[3] or (inbytes[6] shr 3)
    result = 4
  if length >= 8:
    outbytes[4] = (inbytes[6] and 7'u8) shl 5
    outbytes[4] = outbytes[4] or (inbytes[7] and 31'u8)
    result = 5

proc encode*(btype: typedesc[Base32Types], inbytes: openarray[byte],
             outstr: var openarray[char], outlen: var int): Base32Status =
  ## Encode array of bytes ``inbytes`` using BASE32 encoding and store
  ## result to ``outstr``. On success ``Base32Status.Success`` will be returned
  ## and ``outlen`` will be set to number of characters stored inside of
  ## ``outstr``. If length of ``outstr`` is not enough then
  ## ``Base32Status.Overrun`` will be returned and ``outlen`` will be set to
  ## number of characters required.
  when (btype is Base32Upper) or (btype is Base32UpperPad):
    const alphabet = RFCUpperCaseAlphabet
  elif (btype is Base32Lower) or (btype is Base32LowerPad):
    const alphabet = RFCLowerCaseAlphabet
  elif (btype is HexBase32Upper) or (btype is HexBase32UpperPad):
    const alphabet = HEXUpperCaseAlphabet
  elif (btype is HexBase32Lower) or (btype is HexBase32LowerPad):
    const alphabet = HEXLowerCaseAlphabet

  if len(inbytes) == 0:
    outlen = 0
    return Base32Status.Success

  let length = btype.encodedLength(len(inbytes))
  if length > len(outstr):
    outlen = length
    return Base32Status.Overrun

  let reminder = len(inbytes) mod 5
  let limit = len(inbytes) - reminder
  var i, k: int
  while i < limit:
    discard convert5to8(inbytes.toOpenArray(i, i + 4),
                        outstr.toOpenArray(k, k + 7), 5)
    for j in 0..7:
      outstr[k + j] = chr(alphabet.encode[ord(outstr[k + j])])
    k += 8
    i += 5

  if reminder != 0:
    let left = convert5to8(inbytes.toOpenArray(i, i + reminder - 1),
                           outstr.toOpenArray(k, length - 1), reminder)
    for j in 0..(left - 1):
      outstr[k] = chr(alphabet.encode[ord(outstr[k])])
      inc(k)
    when (btype is Base32UpperPad) or (btype is Base32LowerPad) or
         (btype is HexBase32UpperPad) or (btype is HexBase32LowerPad):
      while k < len(outstr):
        outstr[k] = '='
        inc(k)
  outlen = k
  result = Base32Status.Success

proc encode*(btype: typedesc[Base32Types],
             inbytes: openarray[byte]): string {.inline.} =
  ## Encode array of bytes ``inbytes`` using BASE32 encoding and return
  ## encoded string.
  if len(inbytes) == 0:
    result = ""
  else:
    var length = 0
    result = newString(btype.encodedLength(len(inbytes)))
    if btype.encode(inbytes, result, length) == Base32Status.Success:
      result.setLen(length)
    else:
      result = ""

proc decode*[T: byte|char](btype: typedesc[Base32Types], instr: openarray[T],
             outbytes: var openarray[byte], outlen: var int): Base32Status =
  ## Decode BASE32 string and store array of bytes to ``outbytes``. On success
  ## ``Base32Status.Success`` will be returned and ``outlen`` will be set
  ## to number of bytes stored.
  ##
  ## ## If length of ``outbytes`` is not enough to store decoded bytes, then
  ## ``Base32Status.Overrun`` will be returned and ``outlen`` will be set to
  ## number of bytes required.
  when (btype is Base32Upper) or (btype is Base32UpperPad):
    const alphabet = RFCUpperCaseAlphabet
  elif (btype is Base32Lower) or (btype is Base32LowerPad):
    const alphabet = RFCLowerCaseAlphabet
  elif (btype is HexBase32Upper) or (btype is HexBase32UpperPad):
    const alphabet = HEXUpperCaseAlphabet
  elif (btype is HexBase32Lower) or (btype is HexBase32LowerPad):
    const alphabet = HEXLowerCaseAlphabet

  if len(instr) == 0:
    outlen = 0
    return Base32Status.Success

  let length = btype.decodedLength(len(instr))
  if length > len(outbytes):
    outlen = length
    return Base32Status.Overrun

  var inlen = len(instr)
  when (btype is Base32PadTypes):
    for i in countdown(inlen - 1, 0):
      if instr[i] != '=':
        break
      dec(inlen)

  let reminder = inlen mod 8
  let limit = inlen - reminder
  var buffer: array[8, byte]
  var i, k: int
  while i < limit:
    for j in 0..<8:
      if (cast[byte](instr[i + j]) and 0x80'u8) != 0:
        outlen = 0
        zeroMem(addr outbytes[0], i + 8)
        return Base32Status.Incorrect
      let ch = alphabet.decode[int8(instr[i + j])]
      if ch == -1:
        outlen = 0
        zeroMem(addr outbytes[0], i + 8)
        return Base32Status.Incorrect
      buffer[j] = cast[byte](ch)
    discard convert8to5(buffer, outbytes.toOpenArray(k, k + 4), 8)
    k += 5
    i += 8

  var left = 0
  if reminder != 0:
    if reminder == 1 or reminder == 3 or reminder == 6:
      outlen = 0
      zeroMem(addr outbytes[0], i + 8)
      return Base32Status.Incorrect
    for j in 0..<reminder:
      if (cast[byte](instr[i + j]) and 0x80'u8) != 0:
        outlen = 0
        zeroMem(addr outbytes[0], i + 8)
        result = Base32Status.Incorrect
        return
      let ch = alphabet.decode[int8(instr[i + j])]
      if ch == -1:
        outlen = 0
        zeroMem(addr outbytes[0], i + 8)
        result = Base32Status.Incorrect
        return
      buffer[j] = cast[byte](ch)
    left = convert8to5(buffer.toOpenArray(0, reminder - 1),
                          outbytes.toOpenArray(k, length - 1), reminder)
  outlen = k + left
  result = Base32Status.Success

proc decode*[T: byte|char](btype: typedesc[Base32Types],
                           instr: openarray[T]): seq[byte] =
  ## Decode BASE32 string ``instr`` and return sequence of bytes as result.
  if len(instr) == 0:
    result = newSeq[byte]()
  else:
    var length = 0
    result = newSeq[byte](btype.decodedLength(len(instr)))
    if btype.decode(instr, result, length) == Base32Status.Success:
      result.setLen(length)
    else:
      raise newException(Base32Error, "Incorrect base58 string")
