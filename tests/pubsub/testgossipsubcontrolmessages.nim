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
      let peerId = randomPeerId()
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
      let peerId = randomPeerId()
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      # Build an IHAVE message that contains the same message ID three times
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      # Given the budget is not 0 (because it's not been overridden)
      # When a peer makes an IHAVE request for the a message that `gossipSub` does not have
      let iwants = gossipSub.handleIHave(peer, @[msg])
      # Then `gossipSub` should generate an IWant message for the message
      check:
        peer.iHaveBudget > 0
        iwants.messageIDs.len == 1

    # Peers with budget should request messages. If ids are repeated, only one request should be generated
    block:
      let peerId = randomPeerId()
      let peer = gossipSub.getPubSubPeer(peerId)
      # Add message to `gossipSub`'s message cache
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      # Build an IWANT message that contains the same message ID three times
      let msg = ControlIWant(messageIDs: @[id, id, id])
      # When a peer makes an IWANT request for the a message that `gossipSub` has
      let messages = gossipSub.handleIWant(peer, @[msg])
      # Then `gossipSub` should return the message
      check:
        messages.len == 1

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
    var (receivedIHaves, checkForIHaves) = createCheckForIHave()
    n1.addOnRecvObserver(checkForIHaves)

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
    check:
      receivedIHaves[0] == ControlIHave(topicID: topic, messageIDs: @[messageID])

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
    var (receivedIWants, checkForIWants) = createCheckForIWant()
    n1.addOnRecvObserver(checkForIWants)

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
    check:
      receivedIWants[0] == ControlIWant(messageIDs: @[messageID])

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
    var (receivedIWants, checkForIWants) = createCheckForIWant()
    n0.addOnRecvObserver(checkForIWants)

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
    check:
      receivedIWants[0] == ControlIWant(messageIDs: @[messageID])

  asyncTest "IDONTWANT":
    # 3 nodes: A <=> B <=> C (A & C are NOT connected) 
    let
      topic = "foobar"
      nodes = generateNodes(3, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])
    await connectNodes(nodes[1], nodes[2])

    let (bFinished, handlerB) = createCompleteHandler()

    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, handlerB)
    nodes[2].subscribe(topic, voidTopicHandler)
    await waitSubGraph(nodes, topic)

    check:
      nodes[2].mesh.peers(topic) == 1

    # When we pre-emptively send a dontwant from C to B,
    nodes[2].broadcast(
      nodes[2].mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(idontwant: @[ControlIWant(messageIDs: @[newSeq[byte](10)])])
        )
      ),
      isHighPriority = true,
    )

    # Then B doesn't relay the message to C.
    checkUntilTimeout:
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants[^1].len == 1)

    # When A sends a message to the topic
    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    discard await bFinished

    # Then B sends IDONTWANT to C, but not A
    checkUntilTimeout:
      toSeq(nodes[2].mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 1)
    check:
      toSeq(nodes[0].mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)

  asyncTest "IDONTWANT is broadcasted on publish":
    # 2 nodes: A <=> B
    let
      topic = "foobar"
      nodes =
        generateNodes(2, gossip = true, sendIDontWantOnPublish = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])

    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, voidTopicHandler)
    await waitSubGraph(nodes, topic)

    # When A sends a message to the topic
    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    # Then IDONTWANT is sent to B on publish
    checkUntilTimeout:
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants[^1].len == 1)

  asyncTest "IDONTWANT is sent only for 1.2":
    # 3 nodes: A <=> B <=> C (A & C are NOT connected) 
    let
      topic = "foobar"
      nodeA = generateNodes(1, gossip = true).toGossipSub()[0]
      nodeB = generateNodes(1, gossip = true).toGossipSub()[0]
      nodeC = generateNodes(1, gossip = true, gossipSubVersion = GossipSubCodec_11)
      .toGossipSub()[0]

    startNodesAndDeferStop(@[nodeA, nodeB, nodeC])

    await connectNodes(nodeA, nodeB)
    await connectNodes(nodeB, nodeC)

    let (bFinished, handlerB) = createCompleteHandler()

    nodeA.subscribe(topic, voidTopicHandler)
    nodeB.subscribe(topic, handlerB)
    nodeC.subscribe(topic, voidTopicHandler)
    await waitSubGraph(@[nodeA, nodeB, nodeC], topic)

    check:
      nodeC.mesh.peers(topic) == 1

    # When A sends a message to the topic
    tryPublish await nodeA.publish(topic, newSeq[byte](10000)), 1

    discard await bFinished

    # Then B doesn't send IDONTWANT to both A and C (because C.gossipSubVersion == GossipSubCodec_11)
    await waitForHeartbeat()
    check:
      toSeq(nodeC.mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)
      toSeq(nodeA.mesh.getOrDefault(topic)).anyIt(it.iDontWants[^1].len == 0)
