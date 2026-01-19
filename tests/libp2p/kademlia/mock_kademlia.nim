# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, std/times
import ../../../libp2p/protocols/kademlia/[types, routingtable, protobuf, get]
import ../../../libp2p/[peerid, stream/connection]

type MockKadDHT* = ref object of KadDHT
  findNodeCalls*: seq[Key]
  mismatchedRecordKey*: Opt[Key]
    ## If set, handleGetValue returns Record.key with this value

method findNode*(
    kad: MockKadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  # Track all findNode calls
  kad.findNodeCalls.add(target)
  ## Return only locally known peers
  return kad.rtable.findClosestPeerIds(target, kad.config.replication)

method handleGetValue*(
    kad: MockKadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let wrongKey = kad.mismatchedRecordKey.valueOr:
    # No malicious behavior - call base implementation
    await handleGetValue(KadDHT(kad), conn, msg)
    return

  # Malicious behavior: return record with wrong Record.key
  let maliciousResponse = Message(
    msgType: MessageType.getValue,
    key: msg.key, # Message.key matches request
    record: Opt.some(
      Record(
        key: wrongKey, # Record.key does NOT match
        value: Opt.some(@[1.byte, 2, 3, 4]),
        timeReceived: Opt.some($times.now().utc),
      )
    ),
    closerPeers: @[],
  )

  try:
    await conn.writeLp(maliciousResponse.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send malicious get-value response", conn = conn, err = exc.msg
