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

type
  GetValueResponseType* = enum
    Normal ## Use base implementation
    MismatchedKey ## Return record with wrong Record.key
    EmptyRecord ## Return response without record field
    NoValue ## Return record without value field

  MockKadDHT* = ref object of KadDHT
    findNodeCalls*: seq[Key]
    getValueResponse*: GetValueResponseType

method findNode*(
    kad: MockKadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  kad.findNodeCalls.add(target)
  return kad.rtable.findClosestPeerIds(target, kad.config.replication)

method handleGetValue*(
    kad: MockKadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let response =
    case kad.getValueResponse
    of Normal:
      await handleGetValue(KadDHT(kad), conn, msg)
      return
    of MismatchedKey:
      Message(
        msgType: MessageType.getValue,
        key: msg.key,
        record: Opt.some(
          protobuf.Record(
            key: @[1.byte, 1, 1, 1],
            value: Opt.some(@[1.byte, 2, 3, 4]),
            timeReceived: Opt.some($times.now().utc),
          )
        ),
        closerPeers: @[],
      )
    of EmptyRecord:
      Message(
        msgType: MessageType.getValue,
        key: msg.key,
        record: Opt.none(protobuf.Record),
        closerPeers: @[],
      )
    of NoValue:
      Message(
        msgType: MessageType.getValue,
        key: msg.key,
        record: Opt.some(
          protobuf.Record(
            key: msg.key,
            value: Opt.none(seq[byte]),
            timeReceived: Opt.some($times.now().utc),
          )
        ),
        closerPeers: @[],
      )

  try:
    await conn.writeLp(response.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send mock get-value response", conn = conn, err = exc.msg
