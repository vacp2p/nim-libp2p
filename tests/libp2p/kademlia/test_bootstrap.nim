# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos
import ../../../libp2p/[protocols/kademlia, peerid, switch]
import ../../tools/[lifecycle, unittest]
import ./[mock_kademlia, utils]

suite "KadDHT Bootstrap":
  teardown:
    checkTrackers()

  asyncTest "bootstrap calls findNode on self first and skips empty buckets":
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    check kad.rtable.buckets.len == 0

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Only self lookup should occur
    check:
      kad.findNodeCalls.len == 1
      kad.findNodeCalls[0] == kad.rtable.selfId

  asyncTest "bootstrap skips fresh buckets":
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    # Add peers - they will be fresh (just added)
    kad.populateRoutingTable(5)
    check kad.nonEmptyBuckets().len >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Only self lookup - fresh buckets are skipped
    check kad.findNodeCalls.len == 1

  asyncTest "bootstrap refreshes stale buckets":
    let kad = setupMockKad(findNodeEmpty = true)
    startAndDeferStop(@[kad])

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
    let kad = setupMockKad(findNodeEmpty = true)
    startAndDeferStop(@[kad])

    kad.populateRoutingTable(20)

    # Get non-empty bucket indices
    let bucketIndices = kad.nonEmptyBuckets()
    check bucketIndices.len >= 2

    # Make only the first bucket stale
    let staleBucketIndex = bucketIndices[0]
    makeBucketStale(kad.rtable.buckets[staleBucketIndex])
    check kad.rtable.buckets[staleBucketIndex].isStale()

    # Verify that the rest of non-empty buckets is fresh
    for i in 1 ..< bucketIndices.len:
      check not kad.rtable.buckets[bucketIndices[i]].isStale()

    kad.findNodeCalls = @[]
    await kad.bootstrap()

    # Self lookup + only the stale bucket refresh
    check:
      kad.findNodeCalls.len == 2
      kad.findNodeCalls[0] == kad.rtable.selfId # first call always self lookup

  asyncTest "bootstrap with forceRefresh=true refreshes all non-empty buckets":
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    kad.populateRoutingTable(20)

    let nonEmptyBucketCount = kad.nonEmptyBuckets().len
    check nonEmptyBucketCount >= 1

    kad.findNodeCalls = @[]
    await kad.bootstrap(forceRefresh = true)

    # Self lookup + one lookup per non-empty bucket
    check kad.findNodeCalls.len == nonEmptyBucketCount + 1

  asyncTest "refreshTable operates on the given routing table, not kad.rtable":
    let kad = setupMockKad(findNodeEmpty = true)
    startAndDeferStop(@[kad])

    # Populate kad's own table — these buckets should NOT be refreshed
    kad.populateRoutingTable(10)
    for i in kad.nonEmptyBuckets():
      makeBucketStale(kad.rtable.buckets[i])

    # Build a separate routing table with a different selfId and stale peers
    let otherId = randomPeerId().toKey()
    var otherTable = RoutingTable.new(otherId)
    for _ in 0 ..< 5:
      discard otherTable.insert(randomPeerId())
    for i in 0 ..< otherTable.buckets.len:
      if otherTable.buckets[i].peers.len > 0:
        makeBucketStale(otherTable.buckets[i])

    let otherNonEmpty = block:
      var idxs: seq[int]
      for i, b in otherTable.buckets:
        if b.peers.len > 0:
          idxs.add(i)
      idxs

    kad.findNodeCalls = @[]
    await kad.refreshTable(otherTable, forceRefresh = true)

    # First call is selfId of otherTable, remaining are for otherTable's buckets
    check:
      kad.findNodeCalls.len == otherNonEmpty.len + 1
      kad.findNodeCalls[0] == otherId

suite "KadDHT Bootstrap Component":
  teardown:
    checkTrackers()

  asyncTest "bootstrap discovers new peers through network":
    # 1 hub + 9 nodes bootstrapping from hub
    let hubKad = setupKad()
    startAndDeferStop(@[hubKad])

    let kads = setupKadSwitches(
      9,
      bootstrapNodes = @[(hubKad.switch.peerInfo.peerId, hubKad.switch.peerInfo.addrs)],
    )
    startAndDeferStop(kads)

    # All nodes should know about all other nodes after bootstrap
    for i, kad in kads:
      for j, otherKad in kads:
        if i != j:
          check kad.hasKey(otherKad.rtable.selfId)

  asyncTest "bootstrap with unreachable peer completes gracefully":
    # Fake bootstrap peer with valid address format
    let fakePeerId = randomPeerId()
    let fakeAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/59999").get()]

    let config = testKadConfig(timeout = chronos.milliseconds(100))
    let kad = setupKad(config = config, bootstrapNodes = @[(fakePeerId, fakeAddrs)])
    startAndDeferStop(@[kad])

    check:
      kad.hasKey(fakePeerId.toKey()) # fake peer should be in routing table
      kad.started # node should be operational
