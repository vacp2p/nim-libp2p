import std/endians, times
import ../../peerid
import ./crypto
import ../../utils/sequninit

type SeqNo* = uint32

proc init*(T: typedesc[SeqNo], data: seq[byte]): T =
  var seqNo: SeqNo = 0
  let hash = sha256_hash(data)
  for i in 0 .. 3:
    seqNo = seqNo or (uint32(hash[i]) shl (8 * (3 - i)))
  return seqNo

proc init*(T: typedesc[SeqNo], peerId: PeerId): T =
  SeqNo.init(peerId.data)

proc generate*(seqNo: var SeqNo, messageBytes: seq[byte]) =
  let
    currentTime = getTime().toUnix() * 1000
    currentTimeBytes = newSeqUninit[byte](8)
  bigEndian64(unsafeAddr currentTimeBytes[0], unsafeAddr currentTime)

  let s = SeqNo.init(messageBytes & currentTimeBytes)
  seqNo = (seqNo + s) mod high(uint32)

proc inc*(seqNo: var SeqNo) =
  seqNo = (seqNo + 1) mod high(uint32)
  # TODO: Manage sequence no. overflow in a way that it does not affect re-assembly
