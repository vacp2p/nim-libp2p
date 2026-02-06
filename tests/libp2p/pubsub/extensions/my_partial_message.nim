# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import sets, tables, sequtils, algorithm
import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/partial_message]

type
  MyPartsMetadata* = PartsMetadata
    # MyPartsMetadata uses following metadata pattern:
    # [chunk][meta][chunk][meta][chunk][meta]...
    #   - [chunk] and [meta] are exactly 1 byte
    #   - [chunk] identifies part of full logical message
    #   - [meta] tells if message/peer has or wants chunk
    # Example:
    # 1h2h3h - metadata has chunks 1, 2, 3
    # 1h2w3w - metadata has chunk 1, and wants chunk 2, 3

  Chunk* = int
  Meta* {.size: sizeof(byte).} = enum
    have = byte('h')
    want = byte('w')

proc make(chunks: seq[Chunk], meta: Meta): PartsMetadata =
  var metadata: seq[byte]
  for chunk in chunks.sorted():
    metadata.add(chunk.byte)
    metadata.add(meta.byte)
  return metadata

proc have*(T: typedesc[MyPartsMetadata], chunks: seq[Chunk]): PartsMetadata =
  return make(chunks, Meta.have)

proc want*(T: typedesc[MyPartsMetadata], chunks: seq[Chunk]): PartsMetadata =
  return make(chunks, Meta.want)

template checkLen*(m: PartsMetadata) =
  if m.len mod 2 != 0:
    return err("metadata does not have valid length")

iterator iterChunkMeta(m: PartsMetadata): (Chunk, Meta) =
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
  metadata.add(MyPartsMetadata.have(toSeq(have)))
  metadata.add(MyPartsMetadata.want(toSeq(want)))
  return ok(metadata)

type MyPartialMessage* = ref object of PartialMessage
  # implements PartialMessage as example implementation needed for testing
  groupId*: GroupId
  data*: Table[Chunk, seq[byte]] # holds parts that this partial message has
  want*: seq[Chunk] # holds parts that this partial message wants

method groupId*(m: MyPartialMessage): GroupId {.gcsafe, raises: [].} =
  return m.groupId

method partsMetadata*(m: MyPartialMessage): PartsMetadata {.gcsafe, raises: [].} =
  var metadata: seq[byte]
  metadata.add(MyPartsMetadata.have(toSeq(m.data.keys)))
  metadata.add(MyPartsMetadata.want(m.want))
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
