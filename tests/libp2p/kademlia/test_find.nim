# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, chronicles, std/enumerate, sequtils, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[crypto, unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

proc getRandomPeerId(): PeerId =
  PeerId.random(rng()).get()

proc hasKey(kad: KadDHT, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

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
          setupKadSwitch(PermissiveValidator(), CandSelector())
        else:
          setupKadSwitch(
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
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch4, kad4) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch3.peerInfo.peerId, switch3.peerInfo.addrs)],
    )

    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

    check:
      kad1.hasKey(kad2.rtable.selfId)
      kad2.hasKey(kad1.rtable.selfId)

    check:
      kad1.hasKey(kad3.rtable.selfId)
      kad3.hasKey(kad1.rtable.selfId)

    # kad3 knows about kad2 through kad1
    check kad3.hasKey(kad2.rtable.selfId)

    check:
      kad3.hasKey(kad4.rtable.selfId)
      kad4.hasKey(kad3.rtable.selfId)

    # kad 4 knows all peers of kad 3 too
    check:
      kad4.hasKey(kad1.rtable.selfId)
      kad4.hasKey(kad2.rtable.selfId)

    # force kad2 forget kad3 and kad4
    for b in kad2.rtable.buckets.mitems:
      b.peers = b.peers.filterIt(it.nodeId == kad1.rtable.selfId)

    discard await kad2.findNode(kad4.rtable.selfId)

    # kad2 relearns about kad 3 and 4
    check:
      kad2.hasKey(kad3.rtable.selfId)
      kad2.hasKey(kad4.rtable.selfId)

  asyncTest "Find peer":
    var (switch1, _) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    let res1 = await kad2.findPeer(switch3.peerInfo.peerId)
    check res1.get().peerId == switch3.peerInfo.peerId

    # try to find peer that does not exist
    let res2 = await kad2.findPeer(getRandomPeerId())
    check res2.isErr()

  asyncTest "Find node via refresh stale buckets":
    # Setup: kad1 -> kad2 -> kad3 (kad1 doesn't know kad3)
    let (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    let (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    let (switch3, kad3) = setupKadSwitch(
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
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    # Send FIND_NODE with empty key directly
    let emptyKey: Key = @[]
    let response = await switch2.dispatchFindNode(switch1.peerInfo.peerId, emptyKey)

    # Empty key is accepted and a valid response is returned
    check:
      response.msgType == MessageType.findNode
      response.closerPeers.len == 1

  asyncTest "Find node for own PeerID returns closest peers":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    var (switch3, kad3) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    # kad2 asks kad1 for peers closest to kad2's own PeerID
    let ownKey = kad2.rtable.selfId
    let response = await switch2.dispatchFindNode(switch1.peerInfo.peerId, ownKey)

    check:
      response.msgType == MessageType.findNode
      # kad1 knows kad2 and kad3, should return both as closest peers
      response.closerPeers.len == 2

  asyncTest "Lookup initializes shortlist with k closest from routing table":
    var (switch, kad) = setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Insert peers into routing table
    kad.populateRoutingTable(30)
    let peersInTable = kad.getPeersfromRoutingTable()

    # Initialize LookupState for a random target
    let targetKey = getRandomPeerId().toKey()
    let state = LookupState.init(kad, targetKey)

    # Shortlist contains exactly k=20 peers
    let k = kad.rtable.config.replication
    check state.shortlist.len == k

    # Calculate expected k closest peers
    let expectedClosest =
      peersInTable.sortPeers(targetKey, kad.rtable.config.hasher)[0 ..< k]

    # Shortlist contains exactly the k closest peers
    for peerId in expectedClosest:
      check state.shortlist.hasKey(peerId)

  asyncTest "Lookup selects alpha peers for concurrent querying":
    var (switch, kad) = setupKadSwitch(PermissiveValidator(), CandSelector(), @[])
    defer:
      await switch.stop()

    # Set alpha=3 for easier testing
    kad.config.alpha = 3

    # Insert peers into routing table
    kad.populateRoutingTable(10)
    let peersInTable = kad.getPeersfromRoutingTable()

    # Initialize LookupState
    let targetKey = getRandomPeerId().toKey()
    let state = LookupState.init(kad, targetKey)

    # SelectCloserPeers returns exactly alpha peers when more are available
    let toQuery = state.selectCloserPeers(kad.config.alpha)

    # Exactly alpha=3 peers selected for concurrent query
    check toQuery.len == kad.config.alpha

    # Selected peers are the 3 closest to target
    let expectedClosest = peersInTable.sortPeers(targetKey, kad.rtable.config.hasher)[
      0 ..< kad.config.alpha
    ]
    check toQuery == expectedClosest
