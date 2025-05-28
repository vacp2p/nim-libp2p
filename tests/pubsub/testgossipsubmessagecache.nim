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
