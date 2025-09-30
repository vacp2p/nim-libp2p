import chronicles
import ../../peerid
import times
import stew/endians2

const MetadataSize* = 16

type Metadata* = object
  orig: uint64
  msgId: uint64

proc benchmarkLog*(
    eventName: static[string],
    myPeerId: PeerId,
    startTime: Time,
    metadata: Metadata,
    fromPeerId: Opt[PeerId],
    toPeerId: Opt[PeerId],
) =
  let endTime = getTime()
  let procDelay = (endTime - startTime).inMilliseconds()
  info eventName,
    msgId = metadata.msgId,
    fromPeerId,
    toPeerId,
    myPeerId,
    orig = metadata.orig,
    current = startTime,
    procDelay

proc deserialize*(T: typedesc[Metadata], data: seq[byte]): T =
  doAssert data.len >= MetadataSize
  T(orig: uint64.fromBytesLE(data[0 ..< 8]), msgId: uint64.fromBytesLE(data[8 ..< 16]))

proc serialize*(meta: Metadata): seq[byte] =
  @(meta.orig.toBytesLE()) & @(meta.msgId.uint64.toBytesLE())
