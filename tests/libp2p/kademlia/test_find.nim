# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, std/[enumerate, sets], sequtils, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Find":
  teardown:
    checkTrackers()

  asyncTest "Simple find node":
    let swarmSize = 3
    var switches: seq[Switch]
    var kads: seq[KadDHT]
    for i in 0 ..< swarmSize:
      var (switch, kad) =
        if i == 0:
          await setupKadSwitch(PermissiveValidator(), CandSelector())
        else:
          await setupKadSwitch(
            PermissiveValidator(),
            CandSelector(),
            @[(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)],
          )
      switches.add(switch)
      kads.add(kad)

    var entries = @[kads[0].rtable.selfId]

    #  All the nodes that bootstropped off kad[0] have exactly 1 of each previous nodes, + kads[0], in their buckets
    for i, kad in enumerate(kads[1 ..^ 1]):
      for id in entries:
        check kad.hasKey(id)
      entries.add(kad.rtable.selfId)

    discard await kads[1].findNode(kads[2].rtable.selfId)

    # assert that every node has exactly one entry for the id of every other node
    for id in entries:
      for k in kads:
        if k.rtable.selfId == id:
          continue
        check k.hasKey(id)
    await switches.mapIt(it.stop()).allFutures()

  asyncTest "Relay find node":
    var (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch4, kad4) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch3.peerInfo.peerId, switch3.peerInfo.addrs)],
    )

    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

    check:
      kad1.hasKeys(@[kad2.rtable.selfId, kad3.rtable.selfId])
      kad2.hasKey(kad1.rtable.selfId)
      kad3.hasKey(kad1.rtable.selfId)

    # kad3 knows about kad2 through kad1
    check kad3.hasKey(kad2.rtable.selfId)

    check:
      kad3.hasKey(kad4.rtable.selfId)
      kad4.hasKey(kad3.rtable.selfId)

    # kad 4 knows all peers of kad 3 too
    check:
      kad4.hasKeys(@[kad1.rtable.selfId, kad2.rtable.selfId])

    # force kad2 forget kad3 and kad4
    for b in kad2.rtable.buckets.mitems:
      b.peers = b.peers.filterIt(it.nodeId == kad1.rtable.selfId)

    discard await kad2.findNode(kad4.rtable.selfId)

    # kad2 relearns about kad 3 and 4
    check:
      kad2.hasKeys(@[kad3.rtable.selfId, kad4.rtable.selfId])

  asyncTest "Find node accumulates peers from multiple responses":
    let
      (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (switch2, kad2) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (switch3, kad3) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (switch4, kad4) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad1, kad2, kad3, kad4])

    # Connect nodes in a chain: kad1 <-> kad2 <-> kad3 <-> kad4
    connectNodes(kad1, kad2)
    connectNodes(kad2, kad3)
    connectNodes(kad3, kad4)

    # Verify initial state: each node only knows its neighbors
    check:
      kad1.hasKey(kad2.rtable.selfId)
      kad1.hasNoKeys(@[kad3.rtable.selfId, kad4.rtable.selfId])

      kad2.hasKeys(@[kad1.rtable.selfId, kad3.rtable.selfId])
      not kad2.hasKey(kad4.rtable.selfId)

      kad3.hasKeys(@[kad2.rtable.selfId, kad4.rtable.selfId])
      not kad3.hasKey(kad1.rtable.selfId)

      kad4.hasKey(kad3.rtable.selfId)
      kad4.hasNoKeys(@[kad1.rtable.selfId, kad2.rtable.selfId])

    # kad1 performs lookup for kad4
    # Round 1: kad1 -> kad2, learns kad3
    # Round 2: kad1 -> kad3, learns kad4
    discard await kad1.findNode(kad4.rtable.selfId)

    # kad1 accumulated kad3 and kad4 from iterative responses
    check:
      kad1.hasKeys(@[kad3.rtable.selfId, kad4.rtable.selfId])

  asyncTest "Find node excludes already-queried peers from candidates":
    # Each node knows the other two, creating potential for infinite loops
    # Without exclusion: kad1 queries kad2/kad3 -> they return each other -> repeat
    # With exclusion: kad1 queries kad2/kad3 once, marks them responded, terminates
    let
      (_, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (_, kad2) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (_, kad3) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad1, kad2, kad3])

    # Create fully connected triangle
    connectNodes(kad1, kad2)
    connectNodes(kad2, kad3)
    connectNodes(kad3, kad1)

    # Verify initial state: each node knows the other two
    check:
      kad1.hasKeys(@[kad2.rtable.selfId, kad3.rtable.selfId])
      kad2.hasKeys(@[kad1.rtable.selfId, kad3.rtable.selfId])
      kad3.hasKeys(@[kad1.rtable.selfId, kad2.rtable.selfId])

    # Search for non-existent peer
    # Round 1: kad1 queries kad2 and kad3 (both in routing table)
    # kad2 returns [kad1, kad3], kad3 returns [kad1, kad2]
    # kad2 and kad3 marked as responded
    # No new unqueried candidates -> lookup terminates
    # Without exclusion: would re-query kad2/kad3 until all attempts exhausted
    let targetKey = randomPeerId().toKey()
    let peerIds = await kad1.findNode(targetKey)

    # Lookup completed without hanging (proves exclusion works)
    # Returns both known peers sorted by distance to target
    check peerIds ==
      pluckPeerIds(@[kad2, kad3]).sortPeers(targetKey, kad1.rtable.config.hasher)

  asyncTest "Find peer":
    var (switch1, _) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    let res1 = await kad2.findPeer(switch3.peerInfo.peerId)
    check res1.get().peerId == switch3.peerInfo.peerId

    # try to find peer that does not exist
    let res2 = await kad2.findPeer(randomPeerId())
    check res2.isErr()

  asyncTest "Find node via refresh stale buckets":
    # Setup: kad1 -> kad2 -> kad3 (kad1 doesn't know kad3)
    let (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    let (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    let (switch3, kad3) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch2.peerInfo.peerId, switch2.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    # Force kad1 to forget kad3
    for b in kad1.rtable.buckets.mitems:
      b.peers = b.peers.filterIt(it.nodeId != kad3.rtable.selfId)

    # Make kad2's bucket stale to trigger refresh
    let kad2BucketIdx =
      bucketIndex(kad1.rtable.selfId, kad2.rtable.selfId, kad1.rtable.config.hasher)
    kad1.rtable.buckets[kad2BucketIdx].peers[0].lastSeen = Moment.now() - 40.minutes

    check kad1.rtable.buckets[kad2BucketIdx].isStale()
    check not kad1.hasKey(kad3.rtable.selfId)

    await kad1.bootstrap()

    # kad1 discovers kad3 via kad2
    check kad1.hasKey(kad3.rtable.selfId)

  asyncTest "Find node with empty key returns closest peers":
    var (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    # Send FIND_NODE with empty key directly
    let emptyKey: Key = @[]
    let response =
      (await kad2.dispatchFindNode(switch1.peerInfo.peerId, emptyKey)).value()

    # Empty key is accepted and a valid response is returned
    check:
      response.msgType == MessageType.findNode
      response.closerPeers.len == 1
      response.closerPeers[0].id == kad2.rtable.selfId

  asyncTest "Find node for own PeerID returns closest peers":
    var (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    # kad2 asks kad1 for peers closest to kad2's own PeerID
    let ownKey = kad2.rtable.selfId
    let response =
      (await kad2.dispatchFindNode(switch1.peerInfo.peerId, ownKey)).value()

    let closerPeersIds = response.closerPeers.mapIt(it.id)
    check:
      response.msgType == MessageType.findNode
      # kad1 knows kad2 and kad3, should return both as closest peers
      response.closerPeers.len == 2
      kad2.rtable.selfId in closerPeersIds
      kad3.rtable.selfId in closerPeersIds

  asyncTest "Find node with empty routing table returns empty result":
    let (_, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad1])

    # Routing table is empty (no peers connected)
    check kad1.getPeersfromRoutingTable().len == 0

    let peerIds = await kad1.findNode(randomPeerId().toKey())

    # Returns empty - no peers to query
    check peerIds.len == 0

  asyncTest "Find node continues on individual peer timeout":
    # kad1 knows kad2 (will timeout) and kad3 (responds)
    # kad3 knows kad4
    let
      (_, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (switch2, kad2) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (_, kad3) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
      (_, kad4) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad1, kad3, kad4])

    connectNodes(kad1, kad2)
    connectNodes(kad1, kad3)
    connectNodes(kad3, kad4)

    # Stop kad2 - it won't respond (causes timeout)
    await switch2.stop()

    check not kad1.hasKey(kad4.rtable.selfId)

    # Lookup still succeeds via kad3 despite kad2 timeout
    let peerIds = await kad1.findNode(kad4.rtable.selfId)

    check:
      kad4.switch.peerInfo.peerId in peerIds
      kad1.hasKey(kad4.rtable.selfId)

  asyncTest "Lookup initializes shortlist with k closest from routing table":
    var (switch, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Insert peers into routing table
    kad.populateRoutingTable(30)
    let peersInTable = kad.getPeersfromRoutingTable()

    # Initialize LookupState for a random target
    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kad, targetKey)

    # Shortlist contains exactly k=20 peers
    let k = kad.rtable.config.replication
    check state.shortlist.len == k

    # Calculate expected k closest peers
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kad.rtable.config.hasher).take(k)

    # Shortlist contains exactly the k closest peers
    for peerId in expectedClosest:
      check state.shortlist.hasKey(peerId)

  asyncTest "Lookup selects alpha peers for concurrent querying":
    var (switch, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Set alpha=3 for easier testing
    const alpha = 3
    kad.config.alpha = alpha

    # Insert peers into routing table
    kad.populateRoutingTable(10)
    let peersInTable = kad.getPeersfromRoutingTable()

    # Initialize LookupState
    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kad, targetKey)

    # SelectCloserPeers returns exactly alpha peers when more are available
    let toQuery = state.selectCloserPeers(alpha)

    # Selected peers are the 3 closest to target
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kad.rtable.config.hasher).take(alpha)
    check toQuery == expectedClosest

  asyncTest "Shortlist excludes self peer from candidates":
    let (_, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad])

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let selfPid = kad.switch.peerInfo.peerId
    let otherPeer = randomPeerId()

    # Manually add self and another peer to shortlist
    state.shortlist[selfPid] = xorDistance(selfPid, targetKey, kad.rtable.config.hasher)
    state.shortlist[otherPeer] =
      xorDistance(otherPeer, targetKey, kad.rtable.config.hasher)

    # Self should be excluded from selection
    let selected = state.selectCloserPeers(10)

    check:
      selfPid notin selected
      otherPeer in selected

  asyncTest "updateShortlist ignores duplicate peers":
    let (_, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad])

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let existingPeer = randomPeerId()
    let newPeer = randomPeerId()

    # Add existing peer to shortlist
    state.shortlist[existingPeer] =
      xorDistance(existingPeer, targetKey, kad.rtable.config.hasher)
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
    let (_, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad])

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)
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
    let (_, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await stopNodes(@[kad])

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let peer1 = randomPeerId()
    let peer2 = randomPeerId()
    let peer3 = randomPeerId()

    state.shortlist[peer1] = xorDistance(peer1, targetKey, kad.rtable.config.hasher)
    state.shortlist[peer2] = xorDistance(peer2, targetKey, kad.rtable.config.hasher)
    state.shortlist[peer3] = xorDistance(peer3, targetKey, kad.rtable.config.hasher)

    # Mark peer1 and peer2 as responded
    state.responded.incl(peer1)
    state.responded.incl(peer2)

    # Only peer3 should be selectable
    let selected = state.selectCloserPeers(10)
    check selected == @[peer3]

    # With excludeResponded=false, all are returned
    let allPeers = state.selectCloserPeers(10, excludeResponded = false)
    check allPeers ==
      @[peer1, peer2, peer3].sortPeers(targetKey, kad.rtable.config.hasher)
