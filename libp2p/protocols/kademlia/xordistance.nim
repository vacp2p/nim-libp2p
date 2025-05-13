import ./consts
import ../../peerid
import nimcrypto/sha2

type XorDistance* = array[IdLength, byte]

proc countLeadingZeroBits(b: byte): int =
  for i in 0 .. 7:
    if (b and (0x80'u8 shr i)) != 0:
      return i
  return 8

proc leadingZeros*(dist: XorDistance): int =
  for i in 0 ..< dist.len:
    if dist[i] != 0:
      return i * 8 + countLeadingZeroBits(dist[i])
  return dist.len * 8

proc cmp*(a, b: XorDistance): int =
  for i in 0 ..< IdLength:
    if a[i] < b[i]:
      return -1
    elif a[i] > b[i]:
      return 1
  return 0

proc `<`*(a, b: XorDistance): bool =
  cmp(a, b) < 0

proc `<=`*(a, b: XorDistance): bool =
  cmp(a, b) <= 0

proc xorDistance*(a, b: PeerId): XorDistance =
  let digestA = sha256.digest(a.getBytes()).data
  let digestB = sha256.digest(b.getBytes()).data
  for i in 0 ..< IdLength:
    result[i] = digestA[i] xor digestB[i]
