import ./consts
import ./keys
import nimcrypto/sha2
import ../../peerid

type XorDistance* = array[IdLength, byte]

proc countLeadingZeroBits*(b: byte): int =
  for i in 0 .. 7:
    if (b and (0x80'u8 shr i)) != 0:
      return i
  return 8

proc leadingZeros*(dist: XorDistance): int =
  for i in 0 ..< dist.len:
    if dist[i] != 0:
      return i * 8 + countLeadingZeroBits(dist[i])
  return dist.len * 8

#TODO: Is this a smell? I would expect to return a "is gt/lt/eq" enum
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

proc hashFor(k: Key): seq[byte] =
  return
    @(
      case k.kind
      of KeyType.PeerId:
        sha256.digest(k.peerId.getBytes()).data
      of KeyType.Raw:
        sha256.digest(k.data).data
      of KeyType.Unhashed:
        k.data
    )

proc xorDistance*(a, b: Key): XorDistance =
  let hashA = a.hashFor()
  let hashB = b.hashFor()
  var response: XorDistance
  for i in 0 ..< hashA.len:
    response[i] = hashA[i] xor hashB[i]
  return response

proc xorDistance*(a: PeerId, b: Key): XorDistance =
  xorDistance(a.toKey(), b)
