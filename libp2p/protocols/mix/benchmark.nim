# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
