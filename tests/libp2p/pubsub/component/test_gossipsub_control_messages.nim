# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, std/[sequtils], chronicles
import ../../../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
when defined(libp2p_gossipsub_1_4):
  import ../../../../libp2p/protocols/pubsub/gossipsub/preamblestore
import ../../../tools/[unittest]
import ../utils

suite "GossipSub Component - Control Messages":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "GRAFT messages correctly add peers to mesh":
    let
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
    waitSubscribeStar(nodes, topic)

    # Because of the hack-ish dValues, the peers are added to gossipsub but not GRAFTed to mesh
    checkUntilTimeout:
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

    checkUntilTimeout:
      nodes.allIt(it.mesh.getOrDefault(topic).len == 1)

    # Then the peers are GRAFTed
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received GRAFT for non-subscribed topic":
    let
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
    waitSubscribe(n1, n0, topic)

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

    # Then the peer is not GRAFTed
    checkUntilTimeout:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "PRUNE messages correctly removes peers from mesh":
    let
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
    waitSubscribeStar(nodes, topic)

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a PRUNE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)

    # Then the peer is PRUNEd
    checkUntilTimeout:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When another PRUNE message is sent
    let p0 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_12])
    n1.broadcast(@[p0], RPCMsg(control: some(pruneMessage)), isHighPriority = false)

    # Then the peer is PRUNEd
    checkUntilTimeout:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received PRUNE for non-subscribed topic":
    let
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
    waitSubscribe(n1, n0, topic)

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

    # Then the peer is not PRUNEd
    checkUntilTimeout:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "IHAVE messages correctly advertise message ID to peers":
    let
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
    waitSubscribeStar(nodes, topic)

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)

    # When an IHAVE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)

    # Wait until IHAVE response is received
    # Then the peer has exactly one IHAVE message with the correct message ID
    checkUntilTimeout:
      receivedIHaves[].len == 1 and
        receivedIHaves[0] == ControlIHave(topicID: topic, messageIDs: @[messageID])

  asyncTest "IWANT messages correctly request messages by their IDs":
    let
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
    waitSubscribeStar(nodes, topic)

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)

    # When an IWANT message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(iwantMessage)), isHighPriority = false)

    # Wait until IWANT response is received
    # Then the peer has exactly one IWANT message with the correct message ID
    checkUntilTimeout:
      receivedIWants[].len == 1 and
        receivedIWants[0] == ControlIWant(messageIDs: @[messageID])

  asyncTest "IHAVE for message not held by peer triggers IWANT response to sender":
    let
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
    waitSubscribeStar(nodes, topic)

    # When an IHAVE message is sent from node0
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)

    # Wait until IWANT response is received
    # Then node0 should receive exactly one IWANT message from node1
    checkUntilTimeout:
      receivedIWants[].len == 1 and
        receivedIWants[0] == ControlIWant(messageIDs: @[messageID])

  asyncTest "IDONTWANT":
    let nodes = generateNodes(3, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    # Nodes in chain connection
    await connectNodesChain(nodes)

    let (bFinished, handlerB) = createCompleteHandler()

    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, handlerB)
    nodes[2].subscribe(topic, voidTopicHandler)
    waitSubscribeChain(nodes, topic)

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
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants.anyIt(it.len == 1))

    # When A sends a message to the topic
    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    discard await bFinished

    # Then B sends IDONTWANT to C, but not A
    checkUntilTimeout:
      toSeq(nodes[2].mesh.getOrDefault(topic)).anyIt(it.iDontWants.anyIt(it.len == 1))
    check:
      toSeq(nodes[0].mesh.getOrDefault(topic)).allIt(it.iDontWants.allIt(it.len == 0))

  asyncTest "IDONTWANT is broadcasted on publish":
    let nodes =
      generateNodes(2, gossip = true, sendIDontWantOnPublish = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    # When A sends a message to the topic
    tryPublish await nodes[0].publish(topic, newSeq[byte](10000)), 1

    # Then IDONTWANT is sent to B on publish
    checkUntilTimeout:
      nodes[1].mesh.getOrDefault(topic).anyIt(it.iDontWants.anyIt(it.len == 1))

  when defined(libp2p_gossipsub_1_4):
    asyncTest "emit IMReceiving while handling preamble control msg":
      let
        numberOfNodes = 2
        messageID = @[1.byte, 2, 3, 4]
        nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()
        n0 = nodes[0]
        n1 = nodes[1]

      startNodesAndDeferStop(nodes)

      # And the nodes are connected
      await connectNodesStar(nodes)

      # And both subscribe to the topic
      subscribeAllNodes(nodes, topic, voidTopicHandler)
      waitSubscribeStar(nodes, topic)

      let preambles =
        @[
          ControlPreamble(
            topicID: topic,
            messageID: messageID,
            messageLength: preambleMessageSizeThreshold + 1,
          )
        ]

      let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_14])
      check:
        p1.preambleBudget == PreamblePeerBudget

      n0.handlePreamble(p1, preambles)

      check:
        p1.preambleBudget == PreamblePeerBudget - 1 # Preamble budget should decrease
        p1.heIsSendings.hasKey(messageID)
        n0.ongoingReceives.hasKey(messageID)

      let p2 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_14])
      checkUntilTimeout:
        p2.heIsReceivings.hasKey(messageID)
