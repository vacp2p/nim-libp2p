# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables
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

type MyPartialMessage* = ref object of PartialMessage
  # implements PartialMessage as example implementation need for testing
  groupId*: GroupId
  data*: Table[int, seq[byte]]
  want*: seq[int]

method groupId*(m: MyPartialMessage): GroupId {.gcsafe, raises: [].} =
  return m.groupId

method partsMetadata*(m: MyPartialMessage): PartsMetadata {.gcsafe, raises: [].} =
  var metadata: seq[byte]
  for key, val in m.data:
    metadata.add(byte(key))
    metadata.add(byte(Meta.have))
  for key, val in m.want:
    metadata.add(byte(val))
    metadata.add(byte(Meta.want))
  return metadata

method materializeParts*(
    pm: MyPartialMessage, metadata: PartsMetadata
): Result[PartsData, string] {.gcsafe, raises: [].} =
  if metadata.len mod 2 != 0:
    return err("metadata does not have valid length")

  var data: seq[byte]
  for i in 0 ..< (metadata.len / 2).int:
    let key = metadata[(i * 2)].int
    let val = metadata[(i * 2) + 1]

    if val == byte(Meta.want) and pm.data.hasKey(key):
      try:
        data.add(pm.data[key])
      except KeyError:
        raiseAssert "invalid fullMessage part key"
  ok(data)
