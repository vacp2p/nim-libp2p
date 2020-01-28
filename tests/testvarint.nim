import unittest
import ../libp2p/varint

when defined(nimHasUsed): {.used.}

const PBedgeValues = [
  0'u64, (1'u64 shl 7) - 1'u64,
  (1'u64 shl 7), (1'u64 shl 14) - 1'u64,
  (1'u64 shl 14), (1'u64 shl 21) - 1'u64,
  (1'u64 shl 21), (1'u64 shl 28) - 1'u64,
  (1'u64 shl 28), (1'u64 shl 35) - 1'u64,
  (1'u64 shl 35), (1'u64 shl 42) - 1'u64,
  (1'u64 shl 42), (1'u64 shl 49) - 1'u64,
  (1'u64 shl 49), (1'u64 shl 56) - 1'u64,
  (1'u64 shl 56), (1'u64 shl 63) - 1'u64,
  (1'u64 shl 63), 0xFFFF_FFFF_FFFF_FFFF'u64
]

const PBedgeExpects = [
  "00", "7F",
  "8001", "FF7F",
  "808001", "FFFF7F",
  "80808001", "FFFFFF7F",
  "8080808001", "FFFFFFFF7F",
  "808080808001", "FFFFFFFFFF7F",
  "80808080808001", "FFFFFFFFFFFF7F",
  "8080808080808001", "FFFFFFFFFFFFFF7F",
  "808080808080808001", "FFFFFFFFFFFFFFFF7F",
  "80808080808080808001", "FFFFFFFFFFFFFFFFFF01"
]

const PBedgeSizes = [
  1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10
]

const LPedgeValues = [
  0'u64, (1'u64 shl 7) - 1'u64,
  (1'u64 shl 7), (1'u64 shl 14) - 1'u64,
  (1'u64 shl 14), (1'u64 shl 21) - 1'u64,
  (1'u64 shl 21), (1'u64 shl 28) - 1'u64,
  (1'u64 shl 28), (1'u64 shl 35) - 1'u64,
  (1'u64 shl 35), (1'u64 shl 42) - 1'u64,
  (1'u64 shl 42), (1'u64 shl 49) - 1'u64,
  (1'u64 shl 49), (1'u64 shl 56) - 1'u64,
  (1'u64 shl 56), (1'u64 shl 63) - 1'u64,
]

const LPedgeSizes = [
  1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9
]

const LPedgeExpects = [
  "00", "7F",
  "8001", "FF7F",
  "808001", "FFFF7F",
  "80808001", "FFFFFF7F",
  "8080808001", "FFFFFFFF7F",
  "808080808001", "FFFFFFFFFF7F",
  "80808080808001", "FFFFFFFFFFFF7F",
  "8080808080808001", "FFFFFFFFFFFFFF7F",
  "808080808080808001", "FFFFFFFFFFFFFFFF7F",
]

proc hexChar*(c: byte, lowercase: bool = false): string =
  var alpha: int
  if lowercase:
    alpha = ord('a')
  else:
    alpha = ord('A')
  result = newString(2)
  let t1 = ord(c) shr 4
  let t0 = ord(c) and 0x0F
  case t1
  of 0..9: result[0] = chr(t1 + ord('0'))
  else: result[0] = chr(t1 - 10 + alpha)
  case t0:
  of 0..9: result[1] = chr(t0 + ord('0'))
  else: result[1] = chr(t0 - 10 + alpha)

proc toHex*(a: openarray[byte], lowercase: bool = false): string =
  result = ""
  for i in a:
    result = result & hexChar(i, lowercase)

suite "Variable integer test suite":

  test "vsizeof() edge cases test":
    for i in 0..<len(PBedgeValues):
      check vsizeof(PBedgeValues[i]) == PBedgeSizes[i]

  test "[ProtoBuf] Success edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(PBedgeValues):
      buffer.setLen(PBedgeSizes[i])
      check:
        PB.putUVarint(buffer, length, PBedgeValues[i]) == VarintStatus.Success
        PB.getUVarint(buffer, length, value) == VarintStatus.Success
        value == PBedgeValues[i]
        toHex(buffer) == PBedgeExpects[i]

  test "[ProtoBuf] Buffer Overrun edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(PBedgeValues):
      buffer.setLen(PBedgeSizes[i] - 1)
      let res = PB.putUVarint(buffer, length, PBedgeValues[i])
      check:
        res == VarintStatus.Overrun
        length == PBedgeSizes[i]

  test "[ProtoBuf] Buffer Incomplete edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(PBedgeValues):
      buffer.setLen(PBedgeSizes[i])
      check:
        PB.putUVarint(buffer, length, PBedgeValues[i]) == VarintStatus.Success
      buffer.setLen(len(buffer) - 1)
      check:
        PB.getUVarint(buffer, length, value) == VarintStatus.Incomplete

  test "[ProtoBuf] Integer Overflow 32bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(PBedgeValues):
      if PBedgeSizes[i] > 5:
        var value = 0'u32
        buffer.setLen(PBedgeSizes[i])
        check:
          PB.putUVarint(buffer, length, PBedgeValues[i]) == VarintStatus.Success
          PB.getUVarint(buffer, length, value) == VarintStatus.Overflow

  test "[ProtoBuf] Integer Overflow 64bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(PBedgeValues):
      if PBedgeSizes[i] > 9:
        var value = 0'u64
        buffer.setLen(PBedgeSizes[i] + 1)
        check:
          PB.putUVarint(buffer, length, PBedgeValues[i]) == VarintStatus.Success
        buffer[9] = buffer[9] or 0x80'u8
        buffer[10] = 0x01'u8
        check:
          PB.getUVarint(buffer, length, value) == VarintStatus.Overflow

  test "[LibP2P] Success edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(LPedgeValues):
      buffer.setLen(LPedgeSizes[i])
      check:
        LP.putUVarint(buffer, length, LPedgeValues[i]) == VarintStatus.Success
        LP.getUVarint(buffer, length, value) == VarintStatus.Success
        value == LPedgeValues[i]
        toHex(buffer) == LPedgeExpects[i]

  test "[LibP2P] Buffer Overrun edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(LPedgeValues):
      buffer.setLen(PBedgeSizes[i] - 1)
      let res = LP.putUVarint(buffer, length, LPedgeValues[i])
      check:
        res == VarintStatus.Overrun
        length == LPedgeSizes[i]

  test "[LibP2P] Buffer Incomplete edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(LPedgeValues):
      buffer.setLen(LPedgeSizes[i])
      check:
        LP.putUVarint(buffer, length, LPedgeValues[i]) == VarintStatus.Success
      buffer.setLen(len(buffer) - 1)
      check:
        LP.getUVarint(buffer, length, value) == VarintStatus.Incomplete

  test "[LibP2P] Integer Overflow 32bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(LPedgeValues):
      if LPedgeSizes[i] > 5:
        var value = 0'u32
        buffer.setLen(LPedgeSizes[i])
        check:
          LP.putUVarint(buffer, length, LPedgeValues[i]) == VarintStatus.Success
          LP.getUVarint(buffer, length, value) == VarintStatus.Overflow

  test "[LibP2P] Integer Overflow 64bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(LPedgeValues):
      if LPedgeSizes[i] > 8:
        var value = 0'u64
        buffer.setLen(LPedgeSizes[i] + 1)
        check:
          LP.putUVarint(buffer, length, LPedgeValues[i]) == VarintStatus.Success
        buffer[8] = buffer[8] or 0x80'u8
        buffer[9] = 0x01'u8
        check:
          LP.getUVarint(buffer, length, value) == VarintStatus.Overflow

  test "[LibP2P] Over 63bit test":
    var buffer = newSeq[byte](10)
    var length = 0
    check:
      LP.putUVarint(buffer, length,
                    0x7FFF_FFFF_FFFF_FFFF'u64) == VarintStatus.Success
      LP.putUVarint(buffer, length,
                    0x8000_0000_0000_0000'u64) == VarintStatus.Overflow
      LP.putUVarint(buffer, length,
                    0xFFFF_FFFF_FFFF_FFFF'u64) == VarintStatus.Overflow

  test "[LibP2P] Overlong values test":
    const OverlongValues = [
      # Zero bytes at the end
      @[0x81'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8,
        0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8,
        0x80'u8, 0x00'u8],
      # Zero bytes at the middle and zero byte at the end
      @[0x81'u8, 0x80'u8, 0x81'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x81'u8,
        0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8,
        0x81'u8, 0x00'u8],
      # Zero bytes at the middle and zero bytes at the end
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x80'u8, 0x80'u8, 0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x80'u8, 0x80'u8,
        0x00'u8],
      @[0x81'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x81'u8, 0x80'u8,
        0x80'u8, 0x00'u8],
    ]
    var length = 0
    var value = 0'u64

    for item in OverlongValues:
      check:
        LP.getUVarint(item, length, value) == VarintStatus.Overlong
        length == 0
        value == 0

    # We still should be able to decode zero value
    check:
      LP.getUVarint(@[0x00'u8], length, value) == VarintStatus.Success
      length == 1
      value == 0

    # But not overlonged zero value
    check:
      LP.getUVarint(@[0x80'u8, 0x00'u8], length, value) == VarintStatus.Overlong
      length == 0
      value == 0
