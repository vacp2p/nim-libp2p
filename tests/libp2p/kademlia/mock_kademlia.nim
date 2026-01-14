# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles
import ../../../libp2p/protocols/kademlia/[types, routingtable]
import ../../../libp2p/peerid

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

type MockKadDHT* = ref object of KadDHT
  findNodeCalls*: seq[Key]

method findNode*(
    kad: MockKadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  # Track all findNode calls
  kad.findNodeCalls.add(target)
  ## Return only locally known peers
  return kad.rtable.findClosestPeerIds(target, kad.config.replication)
