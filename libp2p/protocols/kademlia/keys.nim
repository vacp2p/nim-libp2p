import nimcrypto/sha2
import ../../peerid
import ./consts
import chronicles
import stew/byteutils

type
  KeyType* {.pure.} = enum
    Unhashed
    Raw
    PeerId

  Key* = object
    case kind*: KeyType
    of KeyType.PeerId:
      peerId*: PeerId
    of KeyType.Raw, KeyType.Unhashed:
      data*: array[IdLength, byte]

proc toKey*(s: seq[byte]): Key =
  doAssert s.len == IdLength
  var data: array[IdLength, byte]
  for i in 0 ..< IdLength:
    data[i] = s[i]
  return Key(kind: KeyType.Raw, data: data)

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
    of KeyType.Raw, KeyType.Unhashed:
      @(k.data)

template `==`*(a, b: Key): bool =
  a.getBytes() == b.getBytes() and a.kind == b.kind

proc shortLog*(k: Key): string =
  case k.kind
  of KeyType.PeerId:
    "PeerId:" & $k.peerId
  of KeyType.Raw, KeyType.Unhashed:
    $k.kind & ":" & toHex(k.data)

chronicles.formatIt(Key):
  shortLog(it)
