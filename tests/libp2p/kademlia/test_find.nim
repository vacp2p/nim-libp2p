# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, sequtils, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Find":
  teardown:
    checkTrackers()

  asyncTest "Simple find node":
    let kads = await setupKadSwitches(3)
    defer:
      await stopNodes(kads)

    # Connect nodes: kads[0] <-> kads[1], kad0 <-> kads[2]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    # kads[1] doesn't know kads[2] yet
    check not kads[1].hasKey(kads[2].rtable.selfId)

    discard await kads[1].findNode(kads[2].rtable.selfId)

    # After findNode, kads[1] discovers kads[2] through kad[0]
    check kads[1].hasKey(kads[2].rtable.selfId)

  asyncTest "Relay find node":
    let kads = await setupKadSwitches(4)
    defer:
      await stopNodes(kads)

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
    let kads = await setupKadSwitches(4)
    defer:
      await stopNodes(kads)

    # Connect nodes in a chain: kads[0] <-> kads[1] <-> kads[2] <-> kads[3]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[1], kads[2])
    connectNodes(kads[2], kads[3])

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

    let kads = await setupKadSwitches(6)
    defer:
      await stopNodes(kads)

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
    let kads = await setupKadSwitches(nodeCount)
    defer:
      await stopNodes(kads)

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
    let kads = await setupKadSwitches(3)
    defer:
      await stopNodes(kads)

    # Create fully connected triangle
    connectNodes(kads[0], kads[1])
    connectNodes(kads[1], kads[2])
    connectNodes(kads[2], kads[0])

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
    let kads = await setupKadSwitches(3)
    defer:
      await stopNodes(kads)

    # Setup: kads[0] <-> kads[1], kads[0] <-> kads[2]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    let res1 = await kads[1].findPeer(kads[2].switch.peerInfo.peerId)
    check res1.get().peerId == kads[2].switch.peerInfo.peerId

    # try to find peer that does not exist
    let res2 = await kads[1].findPeer(randomPeerId())
    check res2.isErr()

  asyncTest "Find node via refresh stale buckets":
    # Setup: kads[0] <-> kads[1] <-> kads[2] (kads[0] doesn't initially know kads[2])
    let kads = await setupKadSwitches(3)
    defer:
      await stopNodes(kads)

    # Connect: kads[0] <-> kads[1], kads[1] <-> kads[2]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[1], kads[2])

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
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

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
    let kads = await setupKadSwitches(3)
    defer:
      await stopNodes(kads)

    # Setup: kads[0] <-> kads[1], kads[0] <-> kads[2]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

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
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    # Routing table is empty (no peers connected)
    check kads[0].getPeersFromRoutingTable().len == 0

    let peerIds = await kads[0].findNode(randomPeerId().toKey())

    # Returns empty - no peers to query
    check peerIds.len == 0

  asyncTest "Find node continues on individual peer timeout":
    # kads[0] knows kads[1] (will timeout) and kads[2] (responds)
    # kads[2] knows kads[3]
    let kads = await setupKadSwitches(4)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[2], kads[3])

    # Stop kads[1] - it won't respond (causes timeout)
    await kads[1].switch.stop()

    check not kads[0].hasKey(kads[3].rtable.selfId)

    # Lookup still succeeds via kads[2] despite kads[1] timeout
    let peerIds = await kads[0].findNode(kads[3].rtable.selfId)

    check:
      kads[3].switch.peerInfo.peerId in peerIds
      kads[0].hasKey(kads[3].rtable.selfId)

  asyncTest "Lookup initializes shortlist with k closest from routing table":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    # Insert peers into routing table
    kads[0].populateRoutingTable(30)
    let peersInTable = kads[0].getPeersFromRoutingTable()

    # Initialize LookupState for a random target
    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kads[0], targetKey)

    # Shortlist contains exactly k=20 peers
    let k = kads[0].rtable.config.replication
    check state.shortlist.len == k

    # Calculate expected k closest peers
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kads[0].rtable.config.hasher).take(k)

    # Shortlist contains exactly the k closest peers
    for peerId in expectedClosest:
      check state.shortlist.hasKey(peerId)

  asyncTest "Lookup selects alpha peers for concurrent querying":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    # Set alpha=3 for easier testing
    const alpha = 3
    kads[0].config.alpha = alpha

    # Insert peers into routing table
    kads[0].populateRoutingTable(10)
    let peersInTable = kads[0].getPeersFromRoutingTable()

    # Initialize LookupState
    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kads[0], targetKey)

    # SelectCloserPeers returns exactly alpha peers when more are available
    let toQuery = state.selectCloserPeers(alpha)

    # Selected peers are the 3 closest to target
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kads[0].rtable.config.hasher).take(alpha)
    check toQuery == expectedClosest

  asyncTest "Shortlist excludes self peer from candidates":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    let selfPid = kads[0].switch.peerInfo.peerId
    let otherPeer = randomPeerId()

    # Manually add self and another peer to shortlist
    state.shortlist[selfPid] =
      xorDistance(selfPid, targetKey, kads[0].rtable.config.hasher)
    state.shortlist[otherPeer] =
      xorDistance(otherPeer, targetKey, kads[0].rtable.config.hasher)

    # Self should be excluded from selection
    let selected = state.selectCloserPeers(10)

    check:
      selfPid notin selected
      otherPeer in selected

  asyncTest "updateShortlist ignores duplicate peers":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    let existingPeer = randomPeerId()
    let newPeer = randomPeerId()

    # Add existing peer to shortlist
    state.shortlist[existingPeer] =
      xorDistance(existingPeer, targetKey, kads[0].rtable.config.hasher)
    let initialSize = state.shortlist.len

    # Create message with existing peer + new peer + duplicate of new peer
    let msg = Message(
      msgType: MessageType.findNode,
      closerPeers:
        @[
          Peer(id: existingPeer.toKey(), addrs: @[]),
          Peer(id: newPeer.toKey(), addrs: @[]),
          Peer(id: newPeer.toKey(), addrs: @[]), # Duplicate
        ],
    )

    let added = state.updateShortlist(msg)

    check:
      # Only newPeer was added (existing and duplicate ignored)
      added.len == 1
      added[0].peerId == newPeer
      state.shortlist.len == initialSize + 1

  asyncTest "updateShortlist skips invalid peer IDs":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)
    let initialSize = state.shortlist.len

    let validPeer = randomPeerId()

    # Create message with invalid peer ID (empty/malformed) and valid peer
    let msg = Message(
      msgType: MessageType.findNode,
      closerPeers:
        @[
          Peer(id: @[], addrs: @[]), # Invalid: empty
          Peer(id: @[0x00, 0x01], addrs: @[]), # Invalid: malformed
          Peer(id: validPeer.toKey(), addrs: @[]), # Valid
        ],
    )

    let added = state.updateShortlist(msg)

    check:
      # Only valid peer was added
      added.len == 1
      added[0].peerId == validPeer
      state.shortlist.len == initialSize + 1

  asyncTest "selectCloserPeers excludes responded peers":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    let peer1 = randomPeerId()
    let peer2 = randomPeerId()
    let peer3 = randomPeerId()

    state.shortlist[peer1] = xorDistance(peer1, targetKey, kads[0].rtable.config.hasher)
    state.shortlist[peer2] = xorDistance(peer2, targetKey, kads[0].rtable.config.hasher)
    state.shortlist[peer3] = xorDistance(peer3, targetKey, kads[0].rtable.config.hasher)

    # Mark peer1 and peer2 as responded
    state.responded[peer1] = RespondedStatus.Success
    state.responded[peer2] = RespondedStatus.Success

    # Only peer3 should be selectable
    let selected = state.selectCloserPeers(10)
    check selected == @[peer3]

    # With excludeResponded=false, all are returned
    let allPeers = state.selectCloserPeers(10, excludeResponded = false)
    check allPeers ==
      @[peer1, peer2, peer3].sortPeers(targetKey, kads[0].rtable.config.hasher)

  asyncTest "Lookup stops when k closest nodes have responded successfully":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    # Add peers
    let peers = state.addRandomPeers(4, targetKey, kads[0].rtable.config.hasher)

    # Set k=3
    kads[0].config.replication = 3

    # only 2 successes, need 3
    state.responded[peers[0]] = RespondedStatus.Failed
    state.responded[peers[1]] = RespondedStatus.Success
    state.responded[peers[2]] = RespondedStatus.Success
    check not state.hasResponsesFromClosestAvailable()

    # stop condition met
    state.responded[peers[3]] = RespondedStatus.Success
    check state.hasResponsesFromClosestAvailable()

  asyncTest "Lookup doesn't stop when k successes but closer peer not responded":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    # Add peers
    let peers = state.addRandomPeers(4, targetKey, kads[0].rtable.config.hasher)

    # Set k=3
    kads[0].config.replication = 3

    # Respond from 0, 2 and 3, but not 1
    # The gap means the condition is not satisfied
    state.responded[peers[0]] = RespondedStatus.Success
    state.responded[peers[2]] = RespondedStatus.Success
    state.responded[peers[3]] = RespondedStatus.Success
    check not state.hasResponsesFromClosestAvailable()

    # Stop condition satisfied
    state.responded[peers[1]] = RespondedStatus.Success
    check state.hasResponsesFromClosestAvailable()

  asyncTest "selectCloserPeers excludes peers that exhausted retries":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    const maxRetries = 3
    kads[0].config.retries = maxRetries

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kads[0], targetKey)

    let peer1 = randomPeerId()
    let peer2 = randomPeerId()
    state.shortlist[peer1] = xorDistance(peer1, targetKey, kads[0].rtable.config.hasher)
    state.shortlist[peer2] = xorDistance(peer2, targetKey, kads[0].rtable.config.hasher)

    check state.selectCloserPeers(10).len == 2

    # peer1 at max retries — still selectable
    state.attempts[peer1] = maxRetries
    check peer1 in state.selectCloserPeers(10)

    # peer1 exceeds retries — excluded
    state.attempts[peer1] = maxRetries + 1
    check peer1 notin state.selectCloserPeers(10)
