## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements BASE58 encoding and decoding procedures.
## This module supports two variants of BASE58 encoding (Bitcoin and Flickr).

type
  Base58Status* {.pure.} = enum
    Error,
    Success,
    Incorrect,
    Overrun

  Base58Alphabet* = object
    decode*: array[128, int8]
    encode*: array[58, uint8]

  BTCBase58* = object
    ## Type to use Bitcoin alphabet
  FLCBase58* = object
    ## Type to use Flickr alphabet
  Base58* = BtcBase58
    ## By default we are using Bitcoin alphabet
  Base58C* = BTCBase58 | FLCBase58
    ## Supported types

  Base58Error* = object of Exception
    ## Base58 specific exception type

proc newAlphabet58*(s: string): Base58Alphabet =
  doAssert(len(s) == 58)
  for i in 0..<len(s):
    result.encode[i] = cast[uint8](s[i])
  for i in 0..<len(result.decode):
    result.decode[i] = -1
  for i in 0..<len(result.encode):
    result.decode[int(result.encode[i])] = int8(i)

const
  BTCAlphabet* = newAlphabet58("123456789ABCDEFGHJKLMNPQRSTUV" &
                               "WXYZabcdefghijkmnopqrstuvwxyz")
  FlickrAlphabet* = newAlphabet58("123456789abcdefghijkmnopqrstu" &
                                  "vwxyzABCDEFGHJKLMNPQRSTUVWXYZ")

proc encode*(btype: typedesc[Base58C], inbytes: openarray[byte],
             outstr: var openarray[char], outlen: var int): Base58Status =
  ## Encode array of bytes ``inbytes`` using BASE58 encoding and store
  ## result to ``outstr``. On success ``Base58Status.Success`` will be returned
  ## and ``outlen`` will be set to number of characters stored inside of
  ## ``outstr``. If length of ``outstr`` is not enough then
  ## ``Base58Status.Overrun`` will be returned and ``outlen`` will be set to
  ## number of characters required.
  when btype is BTCBase58:
    const alphabet = BTCAlphabet
  elif btype is FLCBase58:
    const alphabet = FlickrAlphabet

  let binsz = len(inbytes)
  var zcount = 0

  while zcount < binsz and inbytes[zcount] == 0x00'u8:
    inc(zcount)

  let size = ((binsz - zcount) * 138) div 100 + 1
  var buffer = newSeq[uint8](size)

  var hi = size - 1
  var i = zcount
  var j = size - 1
  while i < binsz:
    var carry = uint32(inbytes[i])
    j = size - 1
    while (j > hi) or (carry != 0'u32):
      carry = carry + uint32(256'u32 * buffer[j])
      buffer[j] = cast[byte](carry mod 58)
      carry = carry div 58
      dec(j)
    hi = j
    inc(i)

  j = 0
  while (j < size) and (buffer[j] == 0x00'u8):
    inc(j)

  let needed = zcount + size - j
  outlen = needed
  if len(outstr) < needed:
    result = Base58Status.Overrun
  else:
    for k in 0..<zcount:
      outstr[k] = cast[char](alphabet.encode[0])
    i = zcount
    while j < size:
      outstr[i] = cast[char](alphabet.encode[buffer[j]])
      inc(j)
      inc(i)
    result = Base58Status.Success

proc encode*(btype: typedesc[Base58C],
             inbytes: openarray[byte]): string {.inline.} =
  ## Encode array of bytes ``inbytes`` using BASE58 encoding and return
  ## encoded string.
  var size = (len(inbytes) * 138) div 100 + 1
  result = newString(size)
  if btype.encode(inbytes, result.toOpenArray(0, size - 1),
                  size) == Base58Status.Success:
    result.setLen(size)
  else:
    result = ""

proc decode*(btype: typedesc[Base58C], instr: string,
             outbytes: var openarray[byte], outlen: var int): Base58Status =
  ## Decode BASE58 string and store array of bytes to ``outbytes``. On success
  ## ``Base58Status.Success`` will be returned and ``outlen`` will be set
  ## to number of bytes stored.
  ##
  ## Length of ``outbytes`` must be equal or more then ``len(instr) + 4``.
  ##
  ## If ``instr`` has characters which are not part of BASE58 alphabet, then
  ## ``Base58Status.Incorrect`` will be returned and ``outlen`` will be set to
  ## ``0``.
  ##
  ## If length of ``outbytes`` is not enough to store decoded bytes, then
  ## ``Base58Status.Overrun`` will be returned and ``outlen`` will be set to
  ## number of bytes required.
  when btype is BTCBase58:
    const alphabet = BTCAlphabet
  elif btype is FLCBase58:
    const alphabet = FlickrAlphabet

  if len(instr) == 0:
    outlen = 0
    return Base58Status.Success

  let binsz = len(instr) + 4
  if len(outbytes) < binsz:
    outlen = binsz
    return Base58Status.Overrun

  var bytesleft = binsz mod 4
  var zeromask: uint32
  if bytesleft != 0:
    zeromask = cast[uint32](0xFFFF_FFFF'u32 shl (bytesleft * 8))

  let size = (binsz + 3) div 4
  var buffer = newSeq[uint32](size)

  var zcount = 0
  while zcount < len(instr) and instr[zcount] == cast[char](alphabet.encode[0]):
    inc(zcount)

  for i in zcount..<len(instr):
    if (cast[byte](instr[i]) and 0x80'u8) != 0:
      outlen = 0
      result = Base58Status.Incorrect
      return
    let ch = alphabet.decode[int8(instr[i])]
    if ch == -1:
      outlen = 0
      result = Base58Status.Incorrect
      return
    var c = cast[uint32](ch)
    for j in countdown(size - 1, 0):
      let t = cast[uint64](buffer[j]) * 58 + c
      c = cast[uint32]((t and 0x3F_0000_0000'u64) shr 32)
      buffer[j] = cast[uint32](t and 0xFFFF_FFFF'u32)
    if c != 0:
      outlen = 0
      result = Base58Status.Incorrect
      return
    if (buffer[0] and zeromask) != 0:
      outlen = 0
      result = Base58Status.Incorrect
      return

  var boffset = 0
  var joffset = 0
  if bytesleft == 3:
    outbytes[boffset] = cast[uint8]((buffer[0] and 0xFF_0000'u32) shr 16)
    inc(boffset)
    bytesleft = 2
  if bytesleft == 2:
    outbytes[boffset] = cast[uint8]((buffer[0] and 0xFF00'u32) shr 8)
    inc(boffset)
    bytesleft = 1
  if bytesleft == 1:
    outbytes[boffset] = cast[uint8]((buffer[0] and 0xFF'u32))
    inc(boffset)
    joffset = 1

  while joffset < size:
    outbytes[boffset + 0] = cast[byte]((buffer[joffset] shr 0x18) and 0xFF)
    outbytes[boffset + 1] = cast[byte]((buffer[joffset] shr 0x10) and 0xFF)
    outbytes[boffset + 2] = cast[byte]((buffer[joffset] shr 0x8) and 0xFF)
    outbytes[boffset + 3] = cast[byte](buffer[joffset] and 0xFF)
    boffset += 4
    inc(joffset)

  outlen = binsz
  var m = 0
  while m < binsz:
    if outbytes[m] != 0x00:
      if zcount > m:
        result = Base58Status.Overrun
        return
      break
    inc(m)
    dec(outlen)

  if m < binsz:
    moveMem(addr outbytes[zcount], addr outbytes[binsz - outlen], outlen)
  outlen += zcount
  result = Base58Status.Success

proc decode*(btype: typedesc[Base58C], instr: string): seq[byte] =
  ## Decode BASE58 string ``instr`` and return sequence of bytes as result.
  if len(instr) > 0:
    var size = len(instr) + 4
    result = newSeq[byte](size)
    if btype.decode(instr, result, size) == Base58Status.Success:
      result.setLen(size)
    else:
      raise newException(Base58Error, "Incorrect base58 string")
