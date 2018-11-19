import unittest
import ../libp2p/protobuf/varint

const edgeValues = [
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
const edgeSizes = [
  1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10
]

suite "ProtoBuf's variable integer test suite":

  test "vsizeof() edge cases test":
    for i in 0..<len(edgeValues):
      check vsizeof(edgeValues[i]) == edgeSizes[i]

  test "Success edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(edgeValues):
      buffer.setLen(edgeSizes[i])
      check:
        putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
        getUVarint(buffer, length, value) == VarintStatus.Success
        value == edgeValues[i]

  test "Buffer Overrun edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(edgeValues):
      buffer.setLen(edgeSizes[i] - 1)
      let res = putUVarint(buffer, length, edgeValues[i])
      check:
        res == VarintStatus.Overrun
        length == edgeSizes[i]

  test "Buffer Incomplete edge cases test":
    var buffer = newSeq[byte]()
    var length = 0
    var value = 0'u64
    for i in 0..<len(edgeValues):
      buffer.setLen(edgeSizes[i])
      check putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
      buffer.setLen(len(buffer) - 1)
      check:
        getUVarint(buffer, length, value) == VarintStatus.Incomplete

  test "Integer Overflow 32bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(edgeValues):
      if edgeSizes[i] > 5:
        var value = 0'u32
        buffer.setLen(edgeSizes[i])
        check:
          putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
          getUVarint(buffer, length, value) == VarintStatus.Overflow

  test "Integer Overflow 64bit test":
    var buffer = newSeq[byte]()
    var length = 0
    for i in 0..<len(edgeValues):
      if edgeSizes[i] > 9:
        var value = 0'u64
        buffer.setLen(edgeSizes[i] + 1)
        check:
          putUVarint(buffer, length, edgeValues[i]) == VarintStatus.Success
        buffer[9] = buffer[9] or 0x80'u8
        buffer[10] = 0x01'u8
        check:
          getUVarint(buffer, length, value) == VarintStatus.Overflow
