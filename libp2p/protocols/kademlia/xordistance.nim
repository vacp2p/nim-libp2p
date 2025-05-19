import ./consts
import ../../peerid

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
  # PeerIDs are already hashed so no need to sha256 i
  let rawA = a.getBytes()
  let rawB = b.getBytes()

  if rawA.len != IdLength or rawB.len != IdLength:
    raise newException(ValueError, "invalid PeerId length")

  var response: XorDistance
  for i in 0 ..< rawA.len:
    response[i] = rawA[i] xor rawB[i]
  return response
