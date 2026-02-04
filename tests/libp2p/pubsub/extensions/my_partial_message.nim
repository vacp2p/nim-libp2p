# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import sets, tables, sequtils
import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/partial_message]

# Metadata pattern:
# [chunk position][ have:1 / want:2]
# Example:
# 11 21 31 - metadata has chunks 1, 2, 3
# 11 22 32 - metadata has chunk 1, and wants chunk 2, 3
# etc ...

type Meta* {.size: sizeof(byte).} = enum
  have = 1
  want = 2

proc rawMetadata*(elements: seq[int], m: Meta): seq[byte] =
  var metadata: seq[byte]
  for pos in elements:
    metadata.add(byte(pos))
    metadata.add(byte(m))
  return metadata

template checkLen(m: PartsMetadata) =
  if m.len mod 2 != 0:
    return err("metadata does not have valid length")

iterator metadataKeyMeta(m: seq[byte]): (int, Meta) =
  for i in 0 ..< (m.len / 2).int:
    let key = m[(i * 2)].int
    let val = m[(i * 2) + 1].Meta
    yield (key, val)

proc unionPartsMetadata*(
    a, b: PartsMetadata
): Result[PartsMetadata, string] {.gcsafe, raises: [].} =
  checkLen(a)
  checkLen(b)

  var have = initHashSet[int]()
  var want = initHashSet[int]()

  for key, meta in metadataKeyMeta(a):
    if meta == Meta.have:
      have.incl(key)
    elif meta == Meta.want:
      want.incl(key)

  for key, meta in metadataKeyMeta(b):
    if meta == Meta.have:
      have.incl(key)
    elif meta == Meta.want:
      want.incl(key)

  for key in have:
    want.excl(key)

  var metadata: seq[byte]
  metadata.add(rawMetadata(toSeq(have), Meta.have))
  metadata.add(rawMetadata(toSeq(want), Meta.want))
  return ok(metadata)

type MyPartialMessage* = ref object of PartialMessage
  # implements PartialMessage as example implementation need for testing
  groupId*: GroupId
  data*: Table[int, seq[byte]] # holds parts that this partial message has
  want*: seq[int] # holds parts that this partial message wants

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
  for key, meta in metadataKeyMeta(metadata):
    if meta == Meta.want and pm.data.hasKey(key):
      try:
        data.add(pm.data[key])
      except KeyError:
        raiseAssert "checked with if"
  ok(data)
