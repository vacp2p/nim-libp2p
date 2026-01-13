# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, chronicles
import ../../../libp2p/[protocols/kademlia, peerid, switch]
import ../../tools/unittest
import ./[mock_kademlia, utils]

trace "chronicles import required for activeChroniclesStream"

proc countNonEmptyBuckets(kad: KadDHT): int =
  var nonEmptyBucketCount = 0
  for bucket in kad.rtable.buckets:
    if bucket.peers.len > 0:
      nonEmptyBucketCount += 1
  nonEmptyBucketCount

suite "KadDHT Bootstrap":
  teardown:
    checkTrackers()

  asyncTest "bootstrap calls findNode on self first and skips empty buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    check kad.rtable.buckets.len == 0

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Only self lookup should occur
    check:
      kad.findNodeCalls.len == 1
      kad.findNodeCalls[0] == kad.rtable.selfId

  asyncTest "bootstrap skips fresh buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Add peers - they will be fresh (just added)
    kad.populateRoutingTable(5)
    check kad.countNonEmptyBuckets() >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Only self lookup - fresh buckets are skipped
    check kad.findNodeCalls.len == 1

  asyncTest "bootstrap refreshes stale buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    let peerId = randomPeerId()
    discard kad.rtable.insert(peerId)

    # Make the bucket stale
    let bucketIdx =
      bucketIndex(kad.rtable.selfId, peerId.toKey(), kad.rtable.config.hasher)
    kad.rtable.buckets[bucketIdx].peers[0].lastSeen = Moment.now() - 40.minutes

    check kad.rtable.buckets[bucketIdx].isStale()

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Self lookup + stale bucket refresh
    check kad.findNodeCalls.len == 2

  asyncTest "bootstrap with forceRefresh=true refreshes all non-empty buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    kad.populateRoutingTable(5)

    let nonEmptyBucketCount = kad.countNonEmptyBuckets()
    check nonEmptyBucketCount >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap(forceRefresh = true)

    # Self lookup + one lookup per non-empty bucket
    check kad.findNodeCalls.len == 1 + nonEmptyBucketCount
