# Nim-LibP2P
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../peerid
import ./kademlia/[types, routingtable]

type MockKadDHT* = ref object of KadDHT

method findNode*(
    kad: MockKadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Return only locally known peers
  return kad.rtable.findClosestPeerIds(target, kad.config.replication)
