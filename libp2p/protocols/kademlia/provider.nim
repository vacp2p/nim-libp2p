# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/sequtils
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid]
import ../protocol
import ./[protobuf, types, find]

proc dispatchAddProvider(
    switch: Switch, peer: PeerId, cid: Cid
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()

  let msg = Message(
    msgType: MessageType.addProvider,
    key: cid.toKey(),
    providerPeers: @[switch.peerInfo.toPeer()],
  )
  await conn.writeLp(msg.encode().buffer)

proc addProvider*(kad: KadDHT, cid: Cid) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Find the closest nodes to the key via FIND_NODE and send ADD_PROVIDER with self's peerInfo to each of them

  let peers = await kad.findNode(cid.toKey())
  for chunk in peers.toChunks(kad.config.alpha):
    let rpcBatch = chunk.mapIt(kad.switch.dispatchAddProvider(it, cid))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

proc handleAddProvider*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let key = msg.key

  if Cid.init(key).isErr():
    error "Received key is an invalid CID", msg = msg, conn = conn, key = key
    return

  # filter out infos that do not match sender's
  let peerBytes = conn.peerId.getBytes()
  for peer in msg.providerPeers.filterIt(it.id == peerBytes):
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", error = error
      continue
    # add provider to peerstore
    kad.switch.peerStore[AddressBook][p] = peer.addrs
