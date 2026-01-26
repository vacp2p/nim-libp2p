# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Iterative Lookup":
  teardown:
    checkTrackers()

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