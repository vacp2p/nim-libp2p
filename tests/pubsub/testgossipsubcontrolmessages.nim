{.used.}

import std/[sequtils]
import stew/byteutils
import utils
import chronicles
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers, ../utils/[futures]

suite "GossipSub Control Messages":
  teardown:
    checkTrackers()

  asyncTest "handleIHave/Iwant tests":
    let topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(30, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.subscribe(topic, voidTopicHandler)

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

  asyncTest "GRAFT messages correctly add peers to mesh":
    # Given 2 nodes
    let
      topic = "foobar"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      # First part of the hack: Weird dValues so peers are not GRAFTed automatically
      dValues = DValues(dLow: some(0), dHigh: some(0), d: some(0), dOut: some(-1))
      nodes = generateNodes(
          numberOfNodes, gossip = true, verifySignature = false, dValues = some(dValues)
        )
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Because of the hack-ish dValues, the peers are added to gossipsub but not GRAFTed to mesh
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # Stop both nodes in order to prevent GRAFT message to be sent by heartbeat 
    await n0.stop()
    await n1.stop()

    # Second part of the hack
    # Set values so peers can be GRAFTed
    let newDValues =
      some(DValues(dLow: some(1), dHigh: some(1), d: some(1), dOut: some(1)))
    n0.parameters.applyDValues(newDValues)
    n1.parameters.applyDValues(newDValues)

    # When a GRAFT message is sent
    let p0 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_12])
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    n1.broadcast(@[p0], RPCMsg(control: some(graftMessage)), isHighPriority = false)

    await waitForPeersInTable(
      nodes, topic, newSeqWith(numberOfNodes, 1), PeerTableType.Mesh
    )

    # Then the peers are GRAFTed
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received GRAFT for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And only node0 subscribes to the topic
    nodes[0].subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a GRAFT message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is not GRAFTed
    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "PRUNE messages correctly removes peers from mesh":
    # Given 2 nodes
    let
      topic = "foo"
      backoff = 1
      pruneMessage = ControlMessage(
        prune: @[ControlPrune(topicID: topic, peers: @[], backoff: uint64(backoff))]
      )
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a PRUNE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is PRUNEd
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When another PRUNE message is sent
    let p0 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_12])
    n1.broadcast(@[p0], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is PRUNEd
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received PRUNE for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      pruneMessage =
        ControlMessage(prune: @[ControlPrune(topicID: topic, peers: @[], backoff: 1)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And only node0 subscribes to the topic
    n0.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a PRUNE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is not PRUNEd
    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "IHAVE messages correctly advertise message ID to peers":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # Given node1 has an IHAVE observer
    var receivedIHave = newFuture[(string, seq[MessageId])]()
    let checkForIhaves = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        for msg in msgs.control.get.ihave:
          receivedIHave.complete((msg.topicID, msg.messageIDs))
    n1.addObserver(PubSubObserver(onRecv: checkForIhaves))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)

    # When an IHAVE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
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
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        for msg in msgs.control.get.iwant:
          receivedIWant.complete(msg.messageIDs)
    n1.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)

    # When an IWANT message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(iwantMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer has the message ID
    let r = await receivedIWant.waitForState(HEARTBEAT_TIMEOUT)
    check:
      r.isCompleted(@[messageID])

  asyncTest "IHAVE for message not held by peer triggers IWANT response to sender":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        for msg in msgs.control.get.iwant:
          receivedIWant.complete(msg.messageIDs)
    n0.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both nodes subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When an IHAVE message is sent from node0
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then node0 should receive an IWANT message from node1 (as node1 doesn't have the message)
    let iWantResult = await receivedIWant.waitForState(HEARTBEAT_TIMEOUT)
    check:
      iWantResult.isCompleted(@[messageID])

  asyncTest "IDONTWANT":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    let
      topic = "foobar"
      nodes = generateNodes(3, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await nodes[1].switch.connect(
      nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, handlerB)
    nodes[2].subscribe(topic, voidTopicHandler)
    await waitSubGraph(nodes, topic)

    check:
      nodes[2].mesh.peers(topic) == 1

    nodes[2].broadcast(
      nodes[2].mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(idontwant: @[ControlIWant(messageIDs: @[newSeq[byte](10)])])
        )
      ),
      isHighPriority = true,
    )
    checkUntilTimeout:
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants[^1].len == 1)

    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    await bFinished

    checkUntilTimeout:
      toSeq(nodes[2].mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 1)
    check:
      toSeq(nodes[0].mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)

  asyncTest "IDONTWANT is broadcasted on publish":
    let
      topic = "foobar"
      nodes =
        generateNodes(2, gossip = true, sendIDontWantOnPublish = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, voidTopicHandler)
    await waitSubGraph(nodes, topic)

    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    checkUntilTimeout:
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants[^1].len == 1)

  asyncTest "IDONTWANT is sent only for 1.2":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    let
      topic = "foobar"
      nodeA = generateNodes(1, gossip = true)[0]
      nodeB = generateNodes(1, gossip = true)[0]
      nodeC = generateNodes(1, gossip = true, gossipSubVersion = GossipSubCodec_11)[0]

    startNodesAndDeferStop(@[nodeA, nodeB, nodeC])

    await nodeA.switch.connect(
      nodeB.switch.peerInfo.peerId, nodeB.switch.peerInfo.addrs
    )
    await nodeB.switch.connect(
      nodeC.switch.peerInfo.peerId, nodeC.switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    nodeA.subscribe(topic, voidTopicHandler)
    nodeB.subscribe(topic, handlerB)
    nodeC.subscribe(topic, voidTopicHandler)
    await waitSubGraph(@[nodeA, nodeB, nodeC], topic)

    var gossipA: GossipSub = GossipSub(nodeA)
    var gossipB: GossipSub = GossipSub(nodeB)
    var gossipC: GossipSub = GossipSub(nodeC)

    check:
      gossipC.mesh.peers(topic) == 1

    tryPublish await nodeA.publish(topic, newSeq[byte](10000)), 1

    await bFinished

    # "check" alone isn't suitable for testing that a condition is true after some time has passed. Below we verify that
    # peers A and C haven't received an IDONTWANT message from B, but we need wait some time for potential in flight messages to arrive.
    await waitForHeartbeat()
    check:
      toSeq(gossipC.mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)
      toSeq(gossipA.mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)
