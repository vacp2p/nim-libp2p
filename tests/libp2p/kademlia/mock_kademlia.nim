# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, chronicles
import ../../../libp2p/protocols/kademlia/[types, routingtable, protobuf, get, provider]
import ../../../libp2p/[peerid, stream/connection]

type MockKadDHT* = ref object of KadDHT
  findNodeCalls*: seq[Key]
  getValueResponse*: Opt[Message]
  handleAddProviderMessage*: Opt[Message]

method findNode*(
    kad: MockKadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  kad.findNodeCalls.add(target)
  return kad.rtable.findClosestPeerIds(target, kad.config.replication)

method handleGetValue*(
    kad: MockKadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let response = kad.getValueResponse.valueOr:
    await handleGetValue(KadDHT(kad), conn, msg)
    return

  try:
    await conn.writeLp(response.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send malicious get-value response", conn = conn, err = exc.msg

method handleAddProvider*(
    kad: MockKadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  await procCall handleAddProvider(
    KadDHT(kad), conn, kad.handleAddProviderMessage.valueOr(msg)
  )
