import nimcrypto/sha2
import ../../peerid
import chronicles
import stew/byteutils

type
  KeyType* {.pure.} = enum
    Raw
    PeerId

  Key* = object
    case kind*: KeyType
    of KeyType.PeerId:
      peerId*: PeerId
    of KeyType.Raw:
      data*: seq[byte]

proc toKey*(s: seq[byte]): Key =
  return Key(kind: KeyType.Raw, data: s)

proc toKey*(p: PeerId): Key =
  return Key(kind: KeyType.PeerId, peerId: p)

proc toPeerId*(k: Key): PeerId {.raises: [ValueError].} =
  if k.kind != KeyType.PeerId:
    raise newException(ValueError, "not a peerId")
  k.peerId

proc getBytes*(k: Key): seq[byte] =
  return
    case k.kind
    of KeyType.PeerId:
      k.peerId.getBytes()
    of KeyType.Raw:
      @(k.data)

template `==`*(a, b: Key): bool =
  a.getBytes() == b.getBytes() and a.kind == b.kind

proc shortLog*(k: Key): string =
  case k.kind
  of KeyType.PeerId:
    "PeerId:" & $k.peerId
  of KeyType.Raw:
    $k.kind & ":" & toHex(k.data)

chronicles.formatIt(Key):
  shortLog(it)
