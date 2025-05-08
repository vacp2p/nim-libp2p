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
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()

    # generate mesh and fanout peers
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d
    for p in peers.keys:
      check not gossipSub.fanout.hasPeerId(topic, p.peerId)
      check not gossipSub.mesh.hasPeerId(topic, p.peerId)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "handleIHave/Iwant tests":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      check false

    proc handler2(topic: string, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.subscribe(topic, handler2)

    # Instantiates 30 peers and connects all of them to the previously defined `gossipSub`
    for i in 0 ..< 30:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      # Add the connection to `gossipSub`, to their `gossipSub.gossipsub` and `gossipSub.mesh` tables
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    # Peers with no budget should not request messages
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      # Add message to `gossipSub`'s message cache
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      # Build an IHAVE message that contains the same message ID three times
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      # Given the peer has no budget to request messages
      peer.iHaveBudget = 0
      # When a peer makes an IHAVE request for the a message that `gossipSub` has
      let iwants = gossipSub.handleIHave(peer, @[msg])
      # Then `gossipSub` should not generate an IWant message for the message, 
      check:
        iwants.messageIDs.len == 0

    # Peers with budget should request messages. If ids are repeated, only one request should be generated
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      # Build an IHAVE message that contains the same message ID three times
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      # Given the budget is not 0 (because it's not been overridden)
      # When a peer makes an IHAVE request for the a message that `gossipSub` does not have
      let iwants = gossipSub.handleIHave(peer, @[msg])
      # Then `gossipSub` should generate an IWant message for the message
      check:
        iwants.messageIDs.len == 1

    # Peers with budget should request messages. If ids are repeated, only one request should be generated
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      # Add message to `gossipSub`'s message cache
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      # Build an IWANT message that contains the same message ID three times
      let msg = ControlIWant(messageIDs: @[id, id, id])
      # When a peer makes an IWANT request for the a message that `gossipSub` has
      let genmsg = gossipSub.handleIWant(peer, @[msg])
      # Then `gossipSub` should return the message
      check:
        genmsg.len == 1

    check gossipSub.mcache.msgs.len == 1

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "messages sent to peers not in the mesh are propagated via gossip":
    let
      numberOfNodes = 5
      topic = "foobar"
      dValues = DValues(dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1))
      nodes = generateNodes(numberOfNodes, gossip = true, dValues = some(dValues))

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # And are interconnected
    await connectNodesStar(nodes)

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForPeersInTable(
      nodes, topic, newSeqWith(numberOfNodes, 4), PeerTableType.Gossipsub
    )

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) > 0
    await waitForHeartbeat()

    # At least one of the nodes should have received an iHave message
    # The check is made this way because the mesh structure changes from run to run
    let receivedIHaves = receivedIHavesRef[]
    check:
      anyIt(receivedIHaves, it > 0)

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
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

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
    let receivedIHaves = receivedIHavesRef[]
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
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

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
    let receivedIHaves = receivedIHavesRef[]
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
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

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
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len >= dValues.dLazy.get()

  asyncTest "iDontWant messages are broadcast immediately after receiving the first message instance":
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iDontWant messages
    var receivedIDontWantsRef = new seq[int]
    addIDontWantObservers(nodes, receivedIDontWantsRef)

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
    let receivedIDontWants = receivedIDontWantsRef[]
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
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard # not used in this test

    let nodes =
      generateNodes(2, gossip = true, enablePX = true) &
      generateNodes(1, gossip = true, sendSignedPeerRecord = true)

    startNodesAndDeferStop(nodes)

    var
      gossip0 = GossipSub(nodes[0])
      gossip1 = GossipSub(nodes[1])
      gossip2 = GossipSub(nodes[2])

    await connectNodesStar(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    nodes[2].subscribe("foobar", handler)
    for x in 0 ..< 3:
      for y in 0 ..< 3:
        if x != y:
          await waitSub(nodes[x], nodes[y], "foobar")

    # Setup record handlers for all nodes
    var
      passed0: Future[void] = newFuture[void]()
      passed2: Future[void] = newFuture[void]()
    gossip0.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == "foobar"
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed0.complete()
    )
    gossip1.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        raiseAssert "should not get here"
    )
    gossip2.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == "foobar"
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed2.complete()
    )

    # Unsubscribe from the topic
    nodes[1].unsubscribe("foobar", handler)

    # Then verify what nodes receive the PX
    let results = await waitForStates(@[passed0, passed2], HEARTBEAT_TIMEOUT)
    check:
      results[0].isCompleted()
      results[1].isCompleted()

  asyncTest "e2e - iDontWant":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let nodes = generateNodes(3, gossip = true, msgIdProvider = dumbMsgIdProvider)

    startNodesAndDeferStop(nodes)

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await nodes[1].switch.connect(
      nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    proc handlerC(topic: string, data: seq[byte]) {.async.} =
      doAssert false

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    nodes[2].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])
    var gossip3: GossipSub = GossipSub(nodes[2])

    check:
      gossip3.mesh.peers("foobar") == 1

    gossip3.broadcast(
      gossip3.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(idontwant: @[ControlIWant(messageIDs: @[newSeq[byte](10)])])
        )
      ),
      isHighPriority = true,
    )
    checkUntilTimeout:
      gossip2.mesh.getOrDefault("foobar").anyIt(it.iDontWants[^1].len == 1)

    tryPublish await nodes[0].publish("foobar", newSeq[byte](10000)), 1

    await bFinished

    checkUntilTimeout:
      toSeq(gossip3.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 1)
    check:
      toSeq(gossip1.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)

  asyncTest "e2e - iDontWant is broadcasted on publish":
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let nodes = generateNodes(
      2, gossip = true, msgIdProvider = dumbMsgIdProvider, sendIDontWantOnPublish = true
    )

    startNodesAndDeferStop(nodes)

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      discard

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip2: GossipSub = GossipSub(nodes[1])

    tryPublish await nodes[0].publish("foobar", newSeq[byte](10000)), 1

    checkUntilTimeout:
      gossip2.mesh.getOrDefault("foobar").anyIt(it.iDontWants[^1].len == 1)

  asyncTest "e2e - iDontWant is sent only for 1.2":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let
      nodeA = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
      nodeB = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
      nodeC = generateNodes(
        1,
        gossip = true,
        msgIdProvider = dumbMsgIdProvider,
        gossipSubVersion = GossipSubCodec_11,
      )[0]

    startNodesAndDeferStop(@[nodeA, nodeB, nodeC])

    await nodeA.switch.connect(
      nodeB.switch.peerInfo.peerId, nodeB.switch.peerInfo.addrs
    )
    await nodeB.switch.connect(
      nodeC.switch.peerInfo.peerId, nodeC.switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    nodeA.subscribe("foobar", handler)
    nodeB.subscribe("foobar", handlerB)
    nodeC.subscribe("foobar", handler)
    await waitSubGraph(@[nodeA, nodeB, nodeC], "foobar")

    var gossipA: GossipSub = GossipSub(nodeA)
    var gossipB: GossipSub = GossipSub(nodeB)
    var gossipC: GossipSub = GossipSub(nodeC)

    check:
      gossipC.mesh.peers("foobar") == 1

    tryPublish await nodeA.publish("foobar", newSeq[byte](10000)), 1

    await bFinished

    # "check" alone isn't suitable for testing that a condition is true after some time has passed. Below we verify that
    # peers A and C haven't received an IDONTWANT message from B, but we need wait some time for potential in flight messages to arrive.
    await waitForHeartbeat()
    check:
      toSeq(gossipC.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)
      toSeq(gossipA.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)

  asyncTest "Peer must send right gosspipsub version":
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let node0 = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
    let node1 = generateNodes(
      1,
      gossip = true,
      msgIdProvider = dumbMsgIdProvider,
      gossipSubVersion = GossipSubCodec_10,
    )[0]

    startNodesAndDeferStop(@[node0, node1])

    await node0.switch.connect(
      node1.switch.peerInfo.peerId, node1.switch.peerInfo.addrs
    )

    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    node0.subscribe("foobar", handler)
    node1.subscribe("foobar", handler)
    await waitSubGraph(@[node0, node1], "foobar")

    var gossip0: GossipSub = GossipSub(node0)
    var gossip1: GossipSub = GossipSub(node1)

    checkUntilTimeout:
      gossip0.mesh.getOrDefault("foobar").toSeq[0].codec == GossipSubCodec_10
    checkUntilTimeout:
      gossip1.mesh.getOrDefault("foobar").toSeq[0].codec == GossipSubCodec_10

  asyncTest "IHAVE messages correctly advertise message ID to peers":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)

    startNodesAndDeferStop(nodes)

    # Given node1 has an IHAVE observer
    var receivedIHave = newFuture[(string, seq[MessageId])]()
    let checkForIhaves = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iHave = msgs.control.get.ihave
        if iHave.len > 0:
          for msg in iHave:
            receivedIHave.complete((msg.topicID, msg.messageIDs))

    g1.addObserver(PubSubObserver(onRecv: checkForIhaves))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true

    # When an IHAVE message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer has the message ID
    let r = await receivedIHave.waitForState(HEARTBEAT_TIMEOUT)
    check:
      r.isCompleted((topic, @[messageID]))

  asyncTest "IWANT messages correctly request messages by their IDs":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      iwantMessage = ControlMessage(iwant: @[ControlIWant(messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)

    startNodesAndDeferStop(nodes)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iWant = msgs.control.get.iwant
        if iWant.len > 0:
          for msg in iWant:
            receivedIWant.complete(msg.messageIDs)

    g1.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true

    # When an IWANT message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(iwantMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer has the message ID
    let r = await receivedIWant.waitForState(HEARTBEAT_TIMEOUT)
    check:
      r.isCompleted(@[messageID])

  asyncTest "IHAVE for non-existent topic":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)

    startNodesAndDeferStop(nodes)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iWant = msgs.control.get.iwant
        if iWant.len > 0:
          for msg in iWant:
            receivedIWant.complete(msg.messageIDs)

    g0.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both nodes subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    # When an IHAVE message is sent from node0
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then node0 should receive an IWANT message from node1 (as node1 doesn't have the message)
    let iWantResult = await receivedIWant.waitForState(HEARTBEAT_TIMEOUT)
    check:
      iWantResult.isCompleted(@[messageID])
