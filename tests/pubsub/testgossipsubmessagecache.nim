{.used.}

import std/[sequtils]
import stew/byteutils
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers

suite "GossipSub Message Cache":
  teardown:
    checkTrackers()

  const
    timeout = 1.seconds
    interval = 50.milliseconds

  asyncTest "Received messages are added to the message cache":
    const
      numberOfNodes = 2
      topic = "foobar"
    let nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When Node0 publishes a message to the topic
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    # Then Node1 receives the message and saves it in the cache 
    checkUntilCustomTimeout(timeout, interval):
      nodes[1].mcache.window(topic).toSeq().len == 1

  asyncTest "Message cache history shifts on heartbeat and is cleared on shift":
    const
      numberOfNodes = 2
      topic = "foobar"
      historyGossip = 3 # mcache window
      historyLength = 5
    let nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        historyGossip = historyGossip,
        historyLength = historyLength,
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When Node0 publishes a message to the topic
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    # Then Node1 receives the message and saves it in the cache 
    checkUntilCustomTimeout(timeout, interval):
      nodes[1].mcache.window(topic).toSeq().len == 1

    let messageId = nodes[1].mcache.window(topic).toSeq()[0]

    # When heartbeat happens, circular history shifts to the next position
    # Waiting for 5(historyLength) heartbeats
    await waitForHeartbeat(historyLength)

    # Then history is cleared when the position with the message is reached again
    # And message is removed
    check:
      nodes[1].mcache.window(topic).toSeq().len == 0
      not nodes[1].mcache.contains(messageId)

  asyncTest "IHave propagation capped by history window":
    # 3 Nodes, Node 0 <==> Node 1 and Node 0 <==> Node 2
    # due to DValues: 1 peer in mesh and 1 peer only in gossip of Node 0
    const
      numberOfNodes = 3
      topic = "foobar"
      historyGossip = 3 # mcache window
      historyLength = 5
    let nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        historyGossip = historyGossip,
        historyLength = historyLength,
        dValues =
          some(DValues(dLow: some(1), dHigh: some(1), d: some(1), dOut: some(0))),
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)

    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Add observer to NodeOutsideMesh for received IHave messages
    var (receivedIHaves, checkForIHaves) = createCheckForIHave()
    let peerOutsideMesh =
      nodes[0].gossipsub[topic].toSeq().filterIt(it notin nodes[0].mesh[topic])[0]
    let nodeOutsideMesh = nodes.getNodeByPeerId(peerOutsideMesh.peerId)
    nodeOutsideMesh.addOnRecvObserver(checkForIHaves)

    # When NodeInsideMesh sends a messages to the topic
    let peerInsideMesh = nodes[0].mesh[topic].toSeq()[0]
    let nodeInsideMesh = nodes.getNodeByPeerId(peerInsideMesh.peerId)
    tryPublish await nodeInsideMesh.publish(topic, newSeq[byte](1000)), 1

    # On each heartbeat, Node0 retrieves messages in its mcache and sends IHave to NodeOutsideMesh
    # On heartbeat, Node0 mcache advances to the next position (rotating the message cache window)
    # Node0 will gossip about messages from the last few positions, depending on the mcache window size (historyGossip)
    # By waiting more than 'historyGossip' (3) heartbeats, we ensure Node0 does not send IHave messages for messages older than the window size
    await waitForHeartbeat(5)

    # Then nodeInsideMesh receives 3 (historyGossip) IHave messages
    check:
      receivedIHaves[].len == historyGossip
