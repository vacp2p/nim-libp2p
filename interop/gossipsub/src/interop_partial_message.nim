# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## InteropPartialMessage — bitmap-based partial message.
##
## Wire format:
##   - Metadata: 1-byte bitmap, bit i == part i present
##   - Partial message: [bitmap: 1 byte][parts: N * 1024 bytes][groupId: 8 bytes]
##   - GroupId: 8 bytes, big-endian uint64
##   - Deterministic data: start = BE(groupId), part i position j = start + i*128 + j

import results, stew/endians2
import ../../../libp2p/[protocols/pubsub/gossipsub/partial_message]

const
  MetadataLen = 1 # uint8
  PartLen* = 1024
  NumParts* = 8 ## parts per message
  GroupIdLen* = 8 ## big-endian uint64
  PositionsPerPart = PartLen div sizeof(uint64) ## 128 uint64

proc hasBit(bitmap: uint8, i: int): bool =
  (bitmap and (1'u8 shl uint8(i))) != 0

proc setBit(bitmap: var uint8, i: int) =
  bitmap = bitmap or (1'u8 shl uint8(i))

type InteropPartialMessage* = ref object of PartialMessage
  bitmap*: uint8 ## bit i == part i present
  parts*: array[NumParts, seq[byte]]
  groupIdBytes*: array[GroupIdLen, byte]

proc newInteropPartialMessage*(groupId: uint64): InteropPartialMessage =
  InteropPartialMessage(groupIdBytes: toBytesBE(groupId))

proc newInteropPartialMessageFromBytes*(
    groupIdBytes: seq[byte]
): InteropPartialMessage =
  doAssert groupIdBytes.len == GroupIdLen, "groupId must be 8 bytes"
  var groupIdArr: array[GroupIdLen, byte]
  copyMem(addr groupIdArr[0], unsafeAddr groupIdBytes[0], GroupIdLen)
  InteropPartialMessage(groupIdBytes: groupIdArr)

proc isComplete*(pm: InteropPartialMessage): bool =
  pm.bitmap == 0b11111111

func partsPresent*(pm: InteropPartialMessage): int =
  var count = 0
  for i in 0 ..< NumParts:
    if pm.bitmap.hasBit(i):
      inc count
  count

proc fillParts*(pm: InteropPartialMessage, bitmap: uint8) =
  ## Fill parts with deterministic data.
  ## start = BigEndian(groupId)
  ## Part i, position j: value == start + i*128 + j
  let start = fromBytesBE(uint64, pm.groupIdBytes)
  for i in 0 ..< NumParts:
    if not bitmap.hasBit(i):
      continue
    var part = newSeq[byte](PartLen)
    var counter = start + uint64(i) * PositionsPerPart
    for j in 0 ..< PositionsPerPart:
      let pos = j * sizeof(uint64)
      part[pos ..< pos + sizeof(uint64)] = @(toBytesBE(counter))
      counter.inc
    pm.parts[i] = part
    pm.bitmap.setBit(i)

proc extend*(pm: InteropPartialMessage, data: seq[byte]): Result[void, string] =
  ## Decode wire format and add new parts.
  ## Wire format: [bitmap: 1 byte][parts: N * 1024 bytes][groupId: 8 bytes]
  if data.len < MetadataLen + GroupIdLen:
    return err("data too short")

  let msgBitmap = data[0]
  let groupIdStart = data.len - GroupIdLen
  let partData = data[MetadataLen ..< groupIdStart]

  # Verify group ID
  if data[groupIdStart ..< data.len] != @(pm.groupIdBytes):
    return err("group ID mismatch")

  if partData.len mod PartLen != 0:
    return err("invalid data length")

  var offset = 0
  for i in 0 ..< NumParts:
    if not msgBitmap.hasBit(i):
      continue # not in message

    if pm.bitmap.hasBit(i):
      offset += PartLen
      continue # already have this part, step past them

    if offset + PartLen > partData.len:
      return err("not enough data for part")

    pm.parts[i] = partData[offset ..< offset + PartLen]
    pm.bitmap.setBit(i)
    offset += PartLen

  ok()

method groupId*(pm: InteropPartialMessage): GroupId {.gcsafe, raises: [].} =
  @(pm.groupIdBytes)

method partsMetadata*(pm: InteropPartialMessage): PartsMetadata {.gcsafe, raises: [].} =
  @[pm.bitmap]

method materializeParts*(
    pm: InteropPartialMessage, metadata: PartsMetadata
): Result[PartsData, string] {.gcsafe, raises: [].} =
  ## Encode parts that the peer doesn't have.
  ## metadata is the peer's 1-byte bitmap (what parts they have).
  ## Returns: [bitmap][parts...][groupId] for parts we have that they don't.
  if metadata.len != MetadataLen:
    return err("invalid metadata length, expected 1 byte")

  let peerBitmap = metadata[0]
  var responseBitmap: uint8 = 0
  var data = newSeq[byte](MetadataLen) # placeholder for bitmap byte

  for i in 0 ..< NumParts:
    if peerBitmap.hasBit(i):
      continue # peer has this part

    if not pm.bitmap.hasBit(i):
      continue # we don't have this part

    responseBitmap.setBit(i)
    data.add(pm.parts[i])

  if responseBitmap == 0:
    return ok(newSeq[byte]()) # nothing to send

  data[0] = responseBitmap
  data.add(@(pm.groupIdBytes))
  ok(data)

proc interopUnionPartsMetadata*(
    a, b: PartsMetadata
): Result[PartsMetadata, string] {.gcsafe, raises: [].} =
  if a.len != MetadataLen or b.len != MetadataLen:
    return err("invalid metadata length, expected 1 byte each")

  ok(@[a[0] or b[0]])
