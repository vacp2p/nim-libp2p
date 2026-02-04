# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, sequtils
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Find":
  teardown:
    checkTrackers()

  asyncTest "Simple find node":
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # Connect nodes: kads[0] <-> kads[1], kad0 <-> kads[2]
    connectNodesHub(kads[0], kads[1 ..^ 1])

    # kads[1] doesn't know kads[2] yet
    check not kads[1].hasKey(kads[2].rtable.selfId)

    discard await kads[1].findNode(kads[2].rtable.selfId)

    # After findNode, kads[1] discovers kads[2] through kad[0]
    check kads[1].hasKey(kads[2].rtable.selfId)

  asyncTest "Relay find node":
    let kads = setupKadSwitches(4)
    startNodesAndDeferStop(kads)

    # Setup: kads[0] <-> kads[1], kads[0] <-> kads[2], kads[2] <-> kads[3]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[2], kads[3])

    check:
      kads[0].hasKeys(@[kads[1].rtable.selfId, kads[2].rtable.selfId])
      kads[2].hasKey(kads[3].rtable.selfId)
      # kads[1] doesn't know kads[2], kads[3] yet
      kads[1].hasNoKeys(@[kads[2].rtable.selfId, kads[3].rtable.selfId])

    discard await kads[1].findNode(kads[3].rtable.selfId)

    # kads[1] discovers kads[2] and kads[3] through relay
    check:
      kads[1].hasKeys(@[kads[2].rtable.selfId, kads[3].rtable.selfId])

  asyncTest "Find node accumulates peers from multiple responses":
    let kads = setupKadSwitches(4)
    startNodesAndDeferStop(kads)

    # Connect nodes in a chain: kads[0] <-> kads[1] <-> kads[2] <-> kads[3]
    connectNodesChain(kads)

    # Verify initial state: each node only knows its neighbors
    check:
      kads[0].hasKey(kads[1].rtable.selfId)
      kads[0].hasNoKeys(@[kads[2].rtable.selfId, kads[3].rtable.selfId])

      kads[1].hasKeys(@[kads[0].rtable.selfId, kads[2].rtable.selfId])
      not kads[1].hasKey(kads[3].rtable.selfId)

      kads[2].hasKeys(@[kads[1].rtable.selfId, kads[3].rtable.selfId])
      not kads[2].hasKey(kads[0].rtable.selfId)

      kads[3].hasKey(kads[2].rtable.selfId)
      kads[3].hasNoKeys(@[kads[0].rtable.selfId, kads[1].rtable.selfId])

    # kads[0] performs lookup for kads[3]
    # Round 1: kads[0] -> kads[1], learns kads[2]
    # Round 2: kads[0] -> kads[2], learns kads[3]
    discard await kads[0].findNode(kads[3].rtable.selfId)

    # kads[0] accumulated kads[2] and kads[3] from iterative responses
    check:
      kads[0].hasKeys(@[kads[2].rtable.selfId, kads[3].rtable.selfId])

    # Queried nodes learned about kads[0]
    check:
      kads[2].hasKey(kads[0].rtable.selfId)
      kads[3].hasKey(kads[0].rtable.selfId)

  asyncTest "Find node merges results from parallel queries":
    #         node[1] - node[3] 
    #        /                 \ 
    # node[0]                   node[5]
    #        \                 /
    #         node[2] - node[4]

    let kads = setupKadSwitches(6)
    startNodesAndDeferStop(kads)

    # Set alpha=2 to ensure both branches are queried in parallel
    kads[0].config.alpha = 2

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[1], kads[3])
    connectNodes(kads[2], kads[4])
    connectNodes(kads[3], kads[5])
    connectNodes(kads[4], kads[5])

    # Verify initial state
    check:
      kads[0].hasKeys(@[kads[1].rtable.selfId, kads[2].rtable.selfId])
      kads[0].hasNoKeys(
        @[kads[3].rtable.selfId, kads[4].rtable.selfId, kads[5].rtable.selfId]
      )

    let targetKey = randomPeerId().toKey()
    let foundPeers = await kads[0].findNode(targetKey)

    # Results from both branches are merged and deduplicated
    check:
      foundPeers ==
        kads[1 .. 5].pluckPeerIds().sortPeers(targetKey, kads[0].rtable.config.hasher)
      kads[0].hasKey(kads[3].rtable.selfId)
      kads[0].hasKey(kads[4].rtable.selfId)
      kads[0].hasKey(kads[5].rtable.selfId)

  asyncTest "Find node returns the actual k closest":
    let nodeCount = 8
    let kads = setupKadSwitches(nodeCount)
    startNodesAndDeferStop(kads)

    # Set replication factor to 3
    let k = 3
    kads[0].config.replication = k

    # Node[0] is directly connected to all other nodes
    connectNodesHub(kads[0], kads[1 ..^ 1])
    check kads[0].getPeersFromRoutingTable().len == nodeCount - 1

    let targetKey = kads[1].rtable.selfId
    let foundPeers = await kads[0].findNode(targetKey)

    # Must return exactly k peers
    check foundPeers.len == k

    # Compute expected k closest by XOR distance
    let allOtherPeers = kads[1 ..< nodeCount].pluckPeerIds()
    let sortedByDistance =
      allOtherPeers.sortPeers(targetKey, kads[0].rtable.config.hasher)
    let expectedKClosest = sortedByDistance[0 ..< k]

    check foundPeers == expectedKClosest

  asyncTest "Find node excludes already-queried peers from candidates":
    # Each node knows the other two, creating potential for infinite loops
    # Without exclusion: kads[0] queries kads[1]/kads[2] -> they return each other -> repeat
    # With exclusion: kads[0] queries kads[1]/kads[2] once, marks them responded, terminates
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # Create fully connected triangle
    connectNodesStar(kads)

    # Verify initial state: each node knows the other two
    check:
      kads[0].hasKeys(@[kads[1].rtable.selfId, kads[2].rtable.selfId])
      kads[1].hasKeys(@[kads[0].rtable.selfId, kads[2].rtable.selfId])
      kads[2].hasKeys(@[kads[0].rtable.selfId, kads[1].rtable.selfId])

    # Search for non-existent peer
    # Round 1: kads[0] queries kads[1] and kads[2] (both in routing table)
    # kads[1] returns [kads[0], kads[2]], kads[2] returns [kads[0], kads[1]]
    # kads[1] and kads[2] marked as responded
    # No new unqueried candidates -> lookup terminates
    # Without exclusion: would re-query kads[1]/kads[2] until all attempts exhausted
    let targetKey = randomPeerId().toKey()
    let peerIds = await kads[0].findNode(targetKey)

    # Lookup completed without hanging (proves exclusion works)
    # Returns both known peers sorted by distance to target
    check peerIds ==
      pluckPeerIds(@[kads[1], kads[2]]).sortPeers(
        targetKey, kads[0].rtable.config.hasher
      )

  asyncTest "Find peer":
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # Setup: kads[0] <-> kads[1], kads[0] <-> kads[2]
    connectNodesHub(kads[0], kads[1 ..^ 1])

    let res1 = await kads[1].findPeer(kads[2].switch.peerInfo.peerId)
    check res1.get().peerId == kads[2].switch.peerInfo.peerId

    # try to find peer that does not exist
    let res2 = await kads[1].findPeer(randomPeerId())
    check res2.isErr()

  asyncTest "Find node via refresh stale buckets":
    # Setup: kads[0] <-> kads[1] <-> kads[2] (kads[0] doesn't initially know kads[2])
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    connectNodesChain(kads)

    check not kads[0].hasKey(kads[2].rtable.selfId)

    # Make kads[1]'s bucket stale to trigger refresh
    let bucketIdx = bucketIndex(
      kads[0].rtable.selfId, kads[1].rtable.selfId, kads[0].rtable.config.hasher
    )
    makeBucketStale(kads[0].rtable.buckets[bucketIdx])

    check kads[0].rtable.buckets[bucketIdx].isStale()
    check not kads[0].hasKey(kads[2].rtable.selfId)

    await kads[0].bootstrap()

    # kads[0] discovers kads[2] via kads[1]
    check kads[0].hasKey(kads[2].rtable.selfId)

  asyncTest "Find node with empty key returns closest peers":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    # Send FIND_NODE with empty key directly
    let emptyKey: Key = @[]
    let response =
      (await kads[1].dispatchFindNode(kads[0].switch.peerInfo.peerId, emptyKey)).value()

    # Empty key is accepted and a valid response is returned
    check:
      response.msgType == MessageType.findNode
      response.closerPeers.len == 1
      response.closerPeers[0].id == kads[1].rtable.selfId

  asyncTest "Find node for own PeerID returns closest peers":
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # Setup: kads[0] <-> kads[1], kads[0] <-> kads[2]
    connectNodesHub(kads[0], kads[1 ..^ 1])

    # kads[1] asks kads[0] for peers closest to kads[1]'s own PeerID
    let ownKey = kads[1].rtable.selfId
    let response =
      (await kads[1].dispatchFindNode(kads[0].switch.peerInfo.peerId, ownKey)).value()

    let closerPeersIds = response.closerPeers.mapIt(it.id)
    check:
      response.msgType == MessageType.findNode
      # kads[0] knows kads[1] and kads[2], should return both as closest peers
      response.closerPeers.len == 2
      kads[1].rtable.selfId in closerPeersIds
      kads[2].rtable.selfId in closerPeersIds

  asyncTest "Find node with empty routing table returns empty result":
    let kads = setupKadSwitches(1)
    startNodesAndDeferStop(kads)

    # Routing table is empty (no peers connected)
    check kads[0].getPeersFromRoutingTable().len == 0

    let peerIds = await kads[0].findNode(randomPeerId().toKey())

    # Returns empty - no peers to query
    check peerIds.len == 0

  asyncTest "Find node continues when peer fails immediately":
    # kads[0] knows kads[1] (will fail immediately) and kads[2] (responds)
    # kads[2] knows kads[3]
    let kads = setupKadSwitches(4)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[2], kads[3])

    # Stop kads[1] - dial will fail immediately with DialFailedError
    # This is marked as RespondedStatus.Failed and NOT retried
    await kads[1].switch.stop()

    check not kads[0].hasKey(kads[3].rtable.selfId)

    # Lookup still succeeds via kads[2] despite kads[1] failure
    let peerIds = await kads[0].findNode(kads[3].rtable.selfId)

    check:
      kads[3].switch.peerInfo.peerId in peerIds
      kads[0].hasKey(kads[3].rtable.selfId)

  asyncTest "Find node retries timed-out peer until max retries exhausted":
    # Test the retry path: peer that doesn't finish within timeout gets retried
    const retries = 5
    let kad =
      setupKad(config = testKadConfig(timeout = 100.milliseconds, retries = retries))
    let mockKad = setupMockKad(handleFindNodeDelay = 500.milliseconds) # > timeout
    let responsiveKad = setupKad()
    startNodesAndDeferStop(@[kad, mockKad, responsiveKad])

    connectNodes(kad, mockKad)
    connectNodes(kad, responsiveKad)

    check mockKad.handleFindNodeCalls == 0

    let peerIds = await kad.findNode(mockKad.rtable.selfId)

    # Lookup terminates gracefully after retry exhaustion
    check:
      responsiveKad.switch.peerInfo.peerId in peerIds
      mockKad.handleFindNodeCalls == retries + 1 # (initial call + retries)
