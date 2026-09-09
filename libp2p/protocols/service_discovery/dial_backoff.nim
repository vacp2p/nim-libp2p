# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Hold back a peer whose service-discovery dial failed. An address policy
## rejects an address no one can reach; only the failure count catches a
## well-formed public address that is simply dead.

{.push raises: [].}

import std/tables
import ../../[multiaddress, peerid]
import ../kademlia/[probe_backoff, types]
import ./[routing_table_manager, types as disco_types]

const MaxDialFailureEntries = 1024
  ## Cache size of failed dials; its keys come from remote replies.

proc dialBackedOff*(
    disco: ServiceDiscovery, peerId: PeerId, addrs: seq[MultiAddress]
): bool =
  disco.dialFailures.backedOff(peerId, addrs)

proc clearDialFailures*(disco: ServiceDiscovery, peerId: PeerId) =
  disco.dialFailures.del(peerId)

proc recordDialFailure*(
    disco: ServiceDiscovery, peerId: PeerId, addrs: seq[MultiAddress]
) =
  let count = disco.dialFailures.recordFailure(
    peerId, addrs, disco.discoConfig.dialBackoffBase, disco.discoConfig.dialBackoffMax,
    MaxDialFailureEntries,
  )

  # The entry outlives the eviction, so a re-admitted peer stays backed off.
  if count >= disco.discoConfig.maxDialFailures:
    disco.rtManager.removePeer(peerId, "unreachable")
