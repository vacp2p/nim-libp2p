import ./consts
import stew/arrayOps
import ./keys
import nimcrypto/sha2
import ../../peerid
import results

type XorDistance* = array[IdLength, byte]
type XorDHasher* = proc(input: seq[byte]): array[IdLength, byte] {.
  raises: [], nimcall, noSideEffect, gcsafe
.}

proc defaultHasher(
    input: seq[byte]
): array[IdLength, byte] {.raises: [], nimcall, noSideEffect, gcsafe.} =
  return sha256.digest(input).data

# useful for testing purposes
proc noOpHasher*(
    input: seq[byte]
): array[IdLength, byte] {.raises: [], nimcall, noSideEffect, gcsafe.} =
  var data: array[IdLength, byte]
  discard data.copyFrom(input)
  return data

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

proc hashFor(k: Key, hasher: Opt[XorDHasher]): seq[byte] =
  return
    @(
      case k.kind
      of KeyType.PeerId:
        hasher.get(defaultHasher)(k.peerId.getBytes())
      of KeyType.Raw:
        hasher.get(defaultHasher)(k.data)
    )

proc xorDistance*(a, b: Key, hasher: Opt[XorDHasher]): XorDistance =
  let hashA = a.hashFor(hasher)
  let hashB = b.hashFor(hasher)
  var response: XorDistance
  for i in 0 ..< hashA.len:
    response[i] = hashA[i] xor hashB[i]
  return response

proc xorDistance*(a: PeerId, b: Key, hasher: Opt[XorDHasher]): XorDistance =
  xorDistance(a.toKey(), b, hasher)
