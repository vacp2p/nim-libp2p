# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../kademlia/[types, find, get]
import ./types

proc findRandom*(
    disco: KademliaDiscovery
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()
  let peerIds = await disco.findNode(randomKey)

  var getFutures: seq[Future[Result[EntryRecord, string]]] = @[]
  for pid in peerIds:
    getFutures.add(disco.getValue(pid.toKey()))

  var records: seq[SignedPeerRecord] = @[]
  await allFutures(getFutures)

  for fut in getFutures:
    if fut.failed:
      trace "future failed", error = fut.error
      continue

    let entry = fut.read().valueOr:
      trace "cannot read future", error
      continue

    let spr = SignedPeerRecord.decode(entry.value).valueOr:
      debug "cannot decode signed peer record", error
      continue

    records.add(spr)

  return records
