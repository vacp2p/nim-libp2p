import ../../peerid
import chronicles
import results
import sugar
import stew/byteutils

type Key* = seq[byte]

proc toKey*(p: PeerId): Key =
  return Key(p.data)

proc toPeerId*(k: Key): Result[PeerId, string] =
  PeerId.init(k).mapErr(x => $x)

proc shortLog*(k: Key): string =
  "key:" & toHex(k)

chronicles.formatIt(Key):
  shortLog(it)
