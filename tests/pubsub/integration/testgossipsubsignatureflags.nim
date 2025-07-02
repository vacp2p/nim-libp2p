# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import unittest2
import chronos
import stew/byteutils
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, pubsub]
import ../../../libp2p/protocols/pubsub/rpc/[messages]
import ../../helpers

suite "GossipSub Integration - Signature Flags":
  const
    topic = "foobar"
    testData = "test message".toBytes()

  teardown:
    checkTrackers()

  asyncTest "Default - messages are signed when sign=true and contain fromPeer and seqno when anonymize=false":
    let nodes = generateNodes(
      2, gossip = true, sign = true, verifySignature = true, anonymize = false
    )

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes.subscribeAllNodes(topic, voidTopicHandler)

    var (receivedMessages, checkForMessage) = createCheckForMessages()
    nodes[1].addOnRecvObserver(checkForMessage)

    tryPublish await nodes[0].publish(topic, testData), 1

    check:
      receivedMessages[0].data == testData
      receivedMessages[0].fromPeer.data.len > 0
      receivedMessages[0].seqno.len > 0
      receivedMessages[0].signature.len > 0
      receivedMessages[0].key.len > 0

  asyncTest "Sign flag - messages are not signed when sign=false":
    let nodes = generateNodes(
      2, gossip = true, sign = false, verifySignature = false, anonymize = false
    )

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes.subscribeAllNodes(topic, voidTopicHandler)

    var (receivedMessages, checkForMessage) = createCheckForMessages()
    nodes[1].addOnRecvObserver(checkForMessage)

    tryPublish await nodes[0].publish(topic, testData), 1

    check:
      receivedMessages[0].data == testData
      receivedMessages[0].signature.len == 0
      receivedMessages[0].key.len == 0

  asyncTest "Anonymize flag - messages are anonymous when anonymize=true":
    let nodes = generateNodes(
      2, gossip = true, sign = true, verifySignature = true, anonymize = true
    ) # anonymize = true takes precedence
    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes.subscribeAllNodes(topic, voidTopicHandler)

    var (receivedMessages, checkForMessage) = createCheckForMessages()
    nodes[1].addOnRecvObserver(checkForMessage)

    let testData = "anonymous message".toBytes()
    tryPublish await nodes[0].publish(topic, testData), 1

    check:
      receivedMessages[0].data == testData
      receivedMessages[0].fromPeer.data.len == 0
      receivedMessages[0].seqno.len == 0
      receivedMessages[0].signature.len == 0
      receivedMessages[0].key.len == 0

  type NodeConfig = tuple[sign: bool, verify: bool, anonymize: bool]
  let scenarios =
    @[
      # (sender_config, receiver_config, should_work)

      # valid combos
      # S default, R default
      ((true, true, false), (true, true, false), true),
      # S default, R anonymous
      ((true, true, false), (false, false, true), true),
      # S anonymous, R anonymous
      ((false, false, true), (false, false, true), true),
      # S only sign, R only verify
      ((true, false, false), (false, true, false), true),
      # S only verify, R only sign
      ((true, true, true), (false, false, false), true),
      # S anonymous (not signed despite the flag), R minimal
      ((false, true, true), (true, false, false), true),
      # S unsigned, R unsigned
      ((false, false, false), (false, false, false), true),

      # invalid combos
      # S anonymous, R default
      ((false, false, true), (true, true, false), false),
      # S unsigned, R anonymous but verify 
      ((false, false, false), (true, true, true), false),
      # S unsigned, R default
      ((false, false, false), (true, true, false), false),
    ]

  for scenario in scenarios:
    let title = "Compatibility matrix: " & $scenario
    asyncTest title:
      let
        (senderConfig, receiverConfig, shouldWork) = scenario
        sender = generateNodes(
          1,
          gossip = true,
          sign = senderConfig[0],
          verifySignature = senderConfig[1],
          anonymize = senderConfig[2],
        )[0]
        receiver = generateNodes(
          1,
          gossip = true,
          sign = receiverConfig[0],
          verifySignature = receiverConfig[1],
          anonymize = receiverConfig[2],
        )[0]
        nodes = @[sender, receiver]

      startNodesAndDeferStop(nodes)
      await connectNodesStar(nodes)

      var messageReceived = false
      proc handler(topic: string, data: seq[byte]) {.async.} =
        messageReceived = true

      nodes.subscribeAllNodes(topic, handler)
      await waitForHeartbeat()

      discard await sender.publish(topic, testData)
      await waitForHeartbeat()

      check:
        messageReceived == shouldWork
