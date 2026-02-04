# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import sets, tables, sequtils, algorithm
import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/partial_message]

# MyPartialMessage uses following metadata pattern:
# [chunk][meta][chunk][meta][chunk][meta]...
#   - [chunk] and [meta] are exactly 1 byte
#   - [chunk] identifies part of full logical message
#   - [meta] tells if peer has or wants chunk
# Example:
# 112131 - metadata has chunks 1, 2, 3
# 112232 - metadata has chunk 1, and wants chunk 2, 3
# etc ...

type 
  Chunk* = int
  Meta* {.size: sizeof(byte).} = enum
   have = 1
   want = 2

proc rawMetadata*(elements: seq[Chunk], m: Meta): seq[byte] =
  var metadata: seq[byte]
  for pos in elements.sorted():
    metadata.add(byte(pos))
    metadata.add(byte(m))
  return metadata

template checkLen*(m: PartsMetadata) =
  if m.len mod 2 != 0:
    return err("metadata does not have valid length")

iterator iterChunkMeta(m: seq[byte]): (Chunk, Meta) =
  for i in 0 ..< (m.len / 2).int:
    let chunk = m[(i * 2)].Chunk
    let meta = m[(i * 2) + 1].Meta
    yield (chunk, meta)

proc unionPartsMetadata*(
    a, b: PartsMetadata
): Result[PartsMetadata, string] {.gcsafe, raises: [].} =
  checkLen(a)
  checkLen(b)

  var have = initHashSet[Chunk]()
  var want = initHashSet[Chunk]()

  for chunk, meta in iterChunkMeta(a):
    if meta == Meta.have:
      have.incl(chunk)
    elif meta == Meta.want:
      want.incl(chunk)

  for chunk, meta in iterChunkMeta(b):
    if meta == Meta.have:
      have.incl(chunk)
    elif meta == Meta.want:
      want.incl(chunk)

  for chunk in have:
    want.excl(chunk)

  var metadata: seq[byte]
  metadata.add(rawMetadata(toSeq(have), Meta.have))
  metadata.add(rawMetadata(toSeq(want), Meta.want))
  return ok(metadata)

type MyPartialMessage* = ref object of PartialMessage
  # implements PartialMessage as example implementation need for testing
  groupId*: GroupId
  data*: Table[Chunk, seq[byte]] # holds parts that this partial message has
  want*: seq[Chunk] # holds parts that this partial message wants

method groupId*(m: MyPartialMessage): GroupId {.gcsafe, raises: [].} =
  return m.groupId

method partsMetadata*(m: MyPartialMessage): PartsMetadata {.gcsafe, raises: [].} =
  var metadata: seq[byte]
  metadata.add(rawMetadata(toSeq(m.data.keys), Meta.have))
  metadata.add(rawMetadata(m.want, Meta.want))
  return metadata

method materializeParts*(
    pm: MyPartialMessage, metadata: PartsMetadata
): Result[PartsData, string] {.gcsafe, raises: [].} =
  checkLen(metadata)

  var data: seq[byte]
  for chunk, meta in iterChunkMeta(metadata):
    if meta == Meta.want and pm.data.hasKey(chunk):
      try:
        data.add(pm.data[chunk])
      except KeyError:
        raiseAssert "checked with if"
  ok(data)

proc toBytes*(s: string): seq[byte] =
  return cast[seq[byte]](s)
