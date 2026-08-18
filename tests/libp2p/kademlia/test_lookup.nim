# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, sequtils, sets, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../../libp2p/protocols/kademlia/[find, types]
import ../../tools/[unittest]
import ./utils.nim

proc recordingDispatch(
    queried: ref seq[PeerId],
    closerPeers = initTable[PeerId, seq[PeerId]](),
    failing = initHashSet[PeerId](),
): DispatchProc =
  ## Answers every query without any I/O, recording who was asked in order and
  ## replying with the peers `closerPeers` maps that peer to. Peers in `failing`
  ## answer with an error, as an unreachable or misbehaving peer would.
  proc(
      kad: KadDHT, peer: PeerId, target: Key
  ): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
    queried[].add(peer)
    if peer in failing:
      return err("peer is not answering")
    let closer = closerPeers.getOrDefault(peer).mapIt(Peer(id: it.getBytes()))
    ok(Message(msgType: MessageType.findNode, closerPeers: closer))

proc setupLookupKad(retries = DefaultRetries): KadDHT =
  ## `alpha = 1` keeps a single query in flight, so the recorded query order
  ## tells the two phases apart.
  setupKad(testKadConfig(replication = 5, retries = retries, alpha = 1, beta = 2))

suite "KadDHT Iterative Lookup":
  teardown:
    checkTrackers()

  test "Lookup initializes shortlist with k closest from routing table":
    let kad = setupKad()

    # Insert peers into routing table
    kad.populateRoutingTable(30)
    let peersInTable = kad.getPeersFromRoutingTable()

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

  test "Lookup seeds from the table it is given":
    let kad = setupKad()
    kad.populateRoutingTable(30)

    let serviceTable = RoutingTable.new(
      randomServiceId(), RoutingTableConfig.new(selfIdPreHashed = true)
    )
    var servicePeers: seq[PeerId]
    for _ in 0 ..< 3:
      let peerId = randomPeerId()
      check serviceTable.insert(peerId)
      servicePeers.add(peerId)

    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kad, targetKey, serviceTable)

    check state.shortlist.len == servicePeers.len
    for peerId in servicePeers:
      check state.shortlist.hasKey(peerId)

  test "Lookup falls back to the main table when the given table is empty":
    let kad = setupKad()
    kad.populateRoutingTable(30)

    let serviceTable = RoutingTable.new(
      randomServiceId(), RoutingTableConfig.new(selfIdPreHashed = true)
    )

    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kad, targetKey, serviceTable)

    let expectedClosest = kad
      .getPeersFromRoutingTable()
      .sortPeers(targetKey, serviceTable.config.hasher)
      .take(kad.config.replication)

    check state.shortlist.len == expectedClosest.len
    for peerId in expectedClosest:
      check state.shortlist.hasKey(peerId)

  test "Lookup selects alpha peers for concurrent querying":
    let kad = setupKad()

    # Set alpha=3 for easier testing
    const alpha = 3
    kad.config.alpha = alpha

    # Insert peers into routing table
    kad.populateRoutingTable(10)
    let peersInTable = kad.getPeersFromRoutingTable()

    # Initialize LookupState
    let targetKey = randomPeerId().toKey()
    let state = LookupState.init(kad, targetKey)

    # SelectCloserPeers returns exactly alpha peers when more are available
    let toQuery = state.selectCloserPeers(alpha)

    # Selected peers are the 3 closest to target
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kad.rtable.config.hasher).take(alpha)
    check toQuery == expectedClosest

  test "Shortlist excludes self peer from candidates":
    let kad = setupKad()

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

  test "updateShortlist ignores duplicate peers":
    let kad = setupKad()

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
      closerPeers: @[
        Peer(id: existingPeer.toKey()),
        Peer(id: newPeer.toKey()),
        Peer(id: newPeer.toKey()), # Duplicate
      ],
    )

    let added = state.updateShortlist(msg)

    check:
      # Only newPeer was added (existing and duplicate ignored)
      added.len == 1
      added[0].peerId == newPeer
      state.shortlist.len == initialSize + 1

  test "updateShortlist skips invalid peer IDs":
    let kad = setupKad()

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)
    let initialSize = state.shortlist.len

    let validPeer = randomPeerId()

    # Create message with invalid peer ID (empty/malformed) and valid peer
    let msg = Message(
      msgType: MessageType.findNode,
      closerPeers: @[
        Peer(id: Opt.none(seq[byte])), # Invalid: empty
        Peer(id: @[0'u8, 1]), # Invalid: malformed
        Peer(id: validPeer.toKey()), # Valid
      ],
    )

    let added = state.updateShortlist(msg)

    check:
      # Only valid peer was added
      added.len == 1
      added[0].peerId == validPeer
      state.shortlist.len == initialSize + 1

  test "selectCloserPeers excludes responded peers":
    let kad = setupKad()

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let peer1 = randomPeerId()
    let peer2 = randomPeerId()
    let peer3 = randomPeerId()

    state.shortlist[peer1] = xorDistance(peer1, targetKey, kad.rtable.config.hasher)
    state.shortlist[peer2] = xorDistance(peer2, targetKey, kad.rtable.config.hasher)
    state.shortlist[peer3] = xorDistance(peer3, targetKey, kad.rtable.config.hasher)

    # Mark peer1 and peer2 as responded
    state.responded[peer1] = RespondedStatus.Success
    state.responded[peer2] = RespondedStatus.Success

    # Only peer3 should be selectable
    let selected = state.selectCloserPeers(10)
    check selected == @[peer3]

    # With excludeResponded=false, all are returned
    let allPeers = state.selectCloserPeers(10, excludeResponded = false)
    check allPeers ==
      @[peer1, peer2, peer3].sortPeers(targetKey, kad.rtable.config.hasher)

  test "Core lookup converges when the beta closest nodes responded successfully":
    let kad = setupKad()

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let peers = state.addRandomPeers(4, targetKey, kad.rtable.config.hasher)
    kad.config.beta = 3

    # only 2 successes, need 3
    state.responded[peers[0]] = RespondedStatus.Failed
    state.responded[peers[1]] = RespondedStatus.Success
    state.responded[peers[2]] = RespondedStatus.Success
    check not state.hasConverged()

    state.responded[peers[3]] = RespondedStatus.Success
    check state.hasConverged()

  test "Core lookup doesn't converge when beta successes but closer peer not responded":
    let kad = setupKad()

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let peers = state.addRandomPeers(4, targetKey, kad.rtable.config.hasher)
    kad.config.beta = 3

    # Respond from 0, 2 and 3, but not 1
    # The gap means the condition is not satisfied
    state.responded[peers[0]] = RespondedStatus.Success
    state.responded[peers[2]] = RespondedStatus.Success
    state.responded[peers[3]] = RespondedStatus.Success
    check not state.hasConverged()

    state.responded[peers[1]] = RespondedStatus.Success
    check state.hasConverged()

  test "Core lookup never waits for more than k responses":
    let kad = setupKad()

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)
    let peers = state.addRandomPeers(4, targetKey, kad.rtable.config.hasher)

    kad.config.beta = 5
    kad.config.replication = 2

    state.responded[peers[0]] = RespondedStatus.Success
    check not state.hasConverged()

    state.responded[peers[1]] = RespondedStatus.Success
    check state.hasConverged()

  test "Follow-up phase targets the k closest peers that did not answer":
    let kad = setupKad()
    kad.config.replication = 3

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)
    let peers = state.addRandomPeers(5, targetKey, kad.rtable.config.hasher)

    state.responded[peers[0]] = RespondedStatus.Success
    state.responded[peers[1]] = RespondedStatus.Failed

    # peers[1] still has retries left, peers[2] was never queried, and peers[3..4]
    # are past the k closest
    check state.followUpPeers() == toHashSet([peers[1], peers[2]])

  test "selectCloserPeers excludes peers that exhausted retries":
    let kad = setupKad()

    const maxRetries = 3
    kad.config.retries = maxRetries

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    let peer1 = randomPeerId()
    let peer2 = randomPeerId()
    state.shortlist[peer1] = xorDistance(peer1, targetKey, kad.rtable.config.hasher)
    state.shortlist[peer2] = xorDistance(peer2, targetKey, kad.rtable.config.hasher)

    check state.selectCloserPeers(10).len == 2

    # peer1 at max retries — still selectable
    state.attempts[peer1] = maxRetries
    check peer1 in state.selectCloserPeers(10)

    # peer1 exceeds retries — excluded
    state.attempts[peer1] = maxRetries + 1
    check peer1 notin state.selectCloserPeers(10)

  test "updateShortlist handles response with more than k peers":
    let kad = setupKad()
    kad.config.replication = 3 # small k for testing

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)
    let initialSize = state.shortlist.len

    # Create message with 10 peers (more than k=3)
    var peers: seq[Peer]
    for i in 0 ..< 10:
      peers.add(Peer(id: randomPeerId().toKey()))

    let msg = Message(msgType: MessageType.findNode, closerPeers: peers)
    let added = state.updateShortlist(msg)

    check:
      # All 10 peers added to shortlist (not capped at k)
      added.len == peers.len
      state.shortlist.len == initialSize + peers.len

      # But selectCloserPeers only returns k=3
      state.selectCloserPeers(kad.config.replication).len == kad.config.replication

  asyncTest "Lookup confirms the k closest peers after converging on beta":
    let kad = setupLookupKad()

    let targetKey = randomPeerId().toKey()
    let known = kad.seedRoutingTable(5, targetKey)

    let queried = new(seq[PeerId])
    discard await kad.iterativeLookup(targetKey, recordingDispatch(queried), noopReply)

    check queried[] == known

  asyncTest "Follow-up phase defers a peer it hears about to the next round":
    let kad = setupLookupKad()

    let targetKey = randomPeerId().toKey()
    # `closest` beats every seeded peer, so the lookup owes it a query
    let (closest, known) = kad.seedRoutingTableBelow(5, targetKey)

    let queried = new(seq[PeerId])
    # The third query is the first one of the follow-up phase
    let dispatch = recordingDispatch(queried, {known[2]: @[closest]}.toTable())
    let state = await kad.iterativeLookup(targetKey, dispatch, noopReply)

    check:
      # the running phase finishes its own set first, then `closest` reopens it
      queried[] == known & @[closest]
      state.responded[closest] == RespondedStatus.Success
      state.allSortedPeers()[0] == closest

  asyncTest "Lookup keeps going for a stop condition the follow-up phase unblocks":
    let kad = setupLookupKad()

    let targetKey = randomPeerId().toKey()
    let (closest, known) = kad.seedRoutingTableBelow(5, targetKey)

    let queried = new(seq[PeerId])
    let dispatch = recordingDispatch(queried, {known[2]: @[closest]}.toTable())
    # Stands in for the quorum of `getValue` and `getProviders`: only the peer
    # the follow-up phase discovers can satisfy it.
    let stopOnClosestReply = proc(state: LookupState): bool {.gcsafe.} =
      state.responded.hasKey(closest)

    let state =
      await kad.iterativeLookup(targetKey, dispatch, noopReply, stopOnClosestReply)

    check:
      closest in queried[]
      state.responded[closest] == RespondedStatus.Success

  asyncTest "Lookup converges past a closest peer that does not answer":
    # No retries, so the dead peer costs exactly one query
    let kad = setupLookupKad(retries = 0)

    let targetKey = randomPeerId().toKey()
    let known = kad.seedRoutingTable(5, targetKey)

    let queried = new(seq[PeerId])
    let dispatch = recordingDispatch(queried, failing = toHashSet([known[0]]))
    let state = await kad.iterativeLookup(targetKey, dispatch, noopReply)

    check:
      # The dead peer holds nothing back and is not asked again
      queried[] == known
      state.responded[known[0]] == RespondedStatus.Failed

  asyncTest "External stop condition skips the follow-up phase":
    let kad = setupLookupKad()

    let targetKey = randomPeerId().toKey()
    let known = kad.seedRoutingTable(5, targetKey)

    let queried = new(seq[PeerId])
    let stopOnFirstReply = proc(state: LookupState): bool {.gcsafe.} =
      state.responded.len >= 1
    discard await kad.iterativeLookup(
      targetKey, recordingDispatch(queried), noopReply, stopOnFirstReply
    )

    check queried[] == known[0 .. 0]
