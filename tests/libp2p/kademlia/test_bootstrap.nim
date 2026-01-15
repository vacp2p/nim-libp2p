# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import ../../../libp2p/[protocols/kademlia, peerid, switch]
import ../../tools/unittest
import ./[mock_kademlia, utils]

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
    check kad.nonEmptyBuckets().len >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Only self lookup - fresh buckets are skipped
    check kad.findNodeCalls.len == 1

  asyncTest "bootstrap refreshes stale buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Add multiple peers to create multiple buckets
    kad.populateRoutingTable(20)

    # Make all buckets stale
    let bucketIndices = kad.nonEmptyBuckets()
    check bucketIndices.len >= 2

    for index in bucketIndices:
      makeBucketStale(kad.rtable.buckets[index])

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Self lookup + one lookup per stale bucket
    check kad.findNodeCalls.len == bucketIndices.len + 1

  asyncTest "bootstrap with mixed fresh and stale buckets refreshes only stale":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    kad.populateRoutingTable(20)

    # Get non-empty bucket indices
    let bucketIndices = kad.nonEmptyBuckets()
    check bucketIndices.len >= 2

    # Make only the first bucket stale
    let staleBucketIndex = bucketIndices[0]
    makeBucketStale(kad.rtable.buckets[staleBucketIndex])
    check kad.rtable.buckets[staleBucketIndex].isStale()

    # Verify that the rest of non-empty buckets is fresh
    for index in bucketIndices[1 ..^ 1]:
      check not kad.rtable.buckets[index].isStale()

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Self lookup + only the stale bucket refresh
    check:
      kad.findNodeCalls.len == 2
      kad.findNodeCalls[0] == kad.rtable.selfId # first call always self lookup

  asyncTest "bootstrap with forceRefresh=true refreshes all non-empty buckets":
    let (switch, kad) =
      await setupMockKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    kad.populateRoutingTable(20)

    let nonEmptyBucketCount = kad.nonEmptyBuckets().len
    check nonEmptyBucketCount >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap(forceRefresh = true)

    # Self lookup + one lookup per non-empty bucket
    check kad.findNodeCalls.len == nonEmptyBucketCount + 1

suite "KadDHT Bootstrap Component":
  teardown:
    checkTrackers()

  asyncTest "bootstrap discovers new peers through network":
    # 1 hub + 9 nodes bootstrapping from hub
    let (hubSwitch, hubKad) =
      await setupKadSwitch(PermissiveValidator(), CandSelector())

    let kads = await setupKadSwitches(
      9, bootstrapNodes = @[(hubSwitch.peerInfo.peerId, hubSwitch.peerInfo.addrs)]
    )
    defer:
      await stopNodes(kads & hubKad)

    # All nodes should know about all other nodes after bootstrap
    for i, kad in kads:
      for j, otherKad in kads:
        if i != j:
          check kad.hasKey(otherKad.rtable.selfId)
