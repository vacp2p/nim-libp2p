import ../../peerid
import ./consts
import chronicles
import stew/byteutils

type
  KeyType* {.pure.} = enum
    Undefined
    Raw
    PeerId

  Key* = object
    case kind*: KeyType
    of KeyType.PeerId:
      peerId*: PeerId
    of KeyType.Raw, KeyType.Undefined:
      data*: array[IdLength, byte]

proc toKey*(s: seq[byte]): Key =
  doAssert s.len == IdLength
  var data: array[IdLength, byte]
  for i in 0 ..< IdLength:
    data[i] = s[i]
  return Key(kind: KeyType.Raw, data: data)

proc toKey*(p: PeerId): Key =
  return Key(kind: KeyType.PeerId, peerId: p)

proc getBytes*(k: Key): seq[byte] =
  return
    case k.kind
    of KeyType.PeerId:
      k.peerId.getBytes()
    of KeyType.Raw, KeyType.Undefined:
      @(k.data)

template `==`*(a, b: Key): bool =
  a.getBytes() == b.getBytes()

proc shortLog*(k: Key): string =
  return
    case k.kind
    of KeyType.PeerId:
      "PeerId:" & $k.peerId
    of KeyType.Raw, KeyType.Undefined:
      $k.kind & ":" & toHex(k.data)

chronicles.formatIt(Key):
  shortLog(it)
