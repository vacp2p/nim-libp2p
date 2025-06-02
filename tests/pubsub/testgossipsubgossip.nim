# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils]
import stew/byteutils
import chronicles
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message]
import ../helpers, ../utils/[futures]

const MsgIdSuccess = "msg id gen success"

suite "GossipSub Gossip Protocol":
  teardown:
    checkTrackers()

  asyncTest "`getGossipPeers` - should gather up to degree D non intersecting peers":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(45, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i in 0 ..< 30:
      let peer = peers[i]
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 30 ..< 45:
      let peer = peers[i]
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d
    for p in gossipPeers.keys:
      check not gossipSub.fanout.hasPeerId(topic, p.peerId)
      check not gossipSub.mesh.hasPeerId(topic, p.peerId)

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == 0

  asyncTest "messages sent to peers not in the mesh are propagated via gossip":
    let
      numberOfNodes = 5
      topic = "foobar"
      dValues = DValues(dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1))
      nodes = generateNodes(numberOfNodes, gossip = true, dValues = some(dValues))
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var messages = addIHaveObservers(nodes)

    # And are interconnected
    await connectNodesStar(nodes)

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    checkUntilTimeout:
      nodes.allIt(it.gossipsub.getOrDefault(topic).len == numberOfNodes - 1)

    # When node 0 sends a message
    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    # At least one of the nodes should have received an iHave message
    # The check is made this way because the mesh structure changes from run to run
    checkUntilTimeout:
      messages[].mapIt(it[].len).anyIt(it > 0)

  asyncTest "adaptive gossip dissemination, dLazy and gossipFactor to 0":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(0)
      )
      nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        dValues = some(dValues),
        gossipFactor = some(0.float),
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var messages = addIHaveObservers(nodes)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 3
    await waitForHeartbeat()

    # None of the nodes should have received an iHave message
    let receivedIHaves = messages[].mapIt(it[].len)
    check:
      filterIt(receivedIHaves, it > 0).len == 0

  asyncTest "adaptive gossip dissemination, with gossipFactor priority":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(4)
      )
      nodes = generateNodes(
        numberOfNodes, gossip = true, dValues = some(dValues), gossipFactor = some(0.5)
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var messages = addIHaveObservers(nodes)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForPeersInTable(@[nodes[0]], topic, @[19], PeerTableType.Gossipsub)

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) in 2 .. 3
    await waitForHeartbeat(2)

    # At least 8 of the nodes should have received an iHave message
    # That's because the gossip factor is 0.5 over 16 available nodes
    let receivedIHaves = messages[].mapIt(it[].len)
    check:
      filterIt(receivedIHaves, it > 0).len >= 8

  asyncTest "adaptive gossip dissemination, with dLazy priority":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(6)
      )
      nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        dValues = some(dValues),
        gossipFactor = some(0.float),
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var messages = addIHaveObservers(nodes)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForPeersInTable(@[nodes[0]], topic, @[19], PeerTableType.Gossipsub)

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) in 2 .. 3
    await waitForHeartbeat(2)

    # At least 6 of the nodes should have received an iHave message
    # That's because the dLazy is 6
    let receivedIHaves = messages[].mapIt(it[].len)
    check:
      filterIt(receivedIHaves, it > 0).len >= dValues.dLazy.get()

  asyncTest "iDontWant messages are broadcast immediately after receiving the first message instance":
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iDontWant messages
    var messages = addIDontWantObservers(nodes)

    # And are connected in a line
    await connectNodes(nodes[0], nodes[1])
    await connectNodes(nodes[1], nodes[2])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForPeersInTable(nodes, topic, @[1, 2, 1], PeerTableType.Gossipsub)

    # When node 0 sends a large message
    let largeMsg = newSeq[byte](1000)
    check (await nodes[0].publish(topic, largeMsg)) == 1
    await waitForHeartbeat()

    # Only node 2 should have received the iDontWant message
    let receivedIDontWants = messages[].mapIt(it[].len)
    check:
      receivedIDontWants[0] == 0
      receivedIDontWants[1] == 0
      receivedIDontWants[2] == 1

  asyncTest "e2e - GossipSub peer exchange":
    # A, B & C are subscribed to something
    # B unsubcribe from it, it should send
    # PX to A & C
    #
    # C sent his SPR, not A
    let
      topic = "foobar"
      nodes =
        generateNodes(2, gossip = true, enablePX = true).toGossipSub() &
        generateNodes(1, gossip = true, sendSignedPeerRecord = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitSubAllNodes(nodes, topic)

    # Setup record handlers for all nodes
    var
      passed0: Future[void] = newFuture[void]()
      passed2: Future[void] = newFuture[void]()
    nodes[0].routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == topic
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed0.complete()
    )
    nodes[1].routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        raiseAssert "should not get here"
    )
    nodes[2].routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == topic
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed2.complete()
    )

    # Unsubscribe from the topic 
    nodes[1].unsubscribe(topic, voidTopicHandler)

    # Then verify what nodes receive the PX
    let results = await waitForStates(@[passed0, passed2], HEARTBEAT_TIMEOUT)
    check:
      results[0].isCompleted()
      results[1].isCompleted()

  asyncTest "Peer must send right gosspipsub version":
    let
      topic = "foobar"
      node0 = generateNodes(1, gossip = true)[0]
      node1 = generateNodes(1, gossip = true, gossipSubVersion = GossipSubCodec_10)[0]

    startNodesAndDeferStop(@[node0, node1])

    await connectNodes(node0, node1)

    node0.subscribe(topic, voidTopicHandler)
    node1.subscribe(topic, voidTopicHandler)
    await waitSubGraph(@[node0, node1], topic)

    var gossip0: GossipSub = GossipSub(node0)
    var gossip1: GossipSub = GossipSub(node1)

    checkUntilTimeout:
      gossip0.mesh.getOrDefault(topic).toSeq[0].codec == GossipSubCodec_10
    checkUntilTimeout:
      gossip1.mesh.getOrDefault(topic).toSeq[0].codec == GossipSubCodec_10
