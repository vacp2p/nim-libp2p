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
import ../../utils/futures

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

    checkUntilTimeout:
      receivedMessages[].len > 0

    let receivedMessage = receivedMessages[][0]
    check:
      receivedMessage.data == testData
      receivedMessage.fromPeer.data.len > 0
      receivedMessage.seqno.len > 0
      receivedMessage.signature.len > 0
      receivedMessage.key.len > 0

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

    checkUntilTimeout:
      receivedMessages[].len > 0

    let receivedMessage = receivedMessages[][0]
    check:
      receivedMessage.data == testData
      receivedMessage.signature.len == 0
      receivedMessage.key.len == 0

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

    checkUntilTimeout:
      receivedMessages[].len > 0

    let receivedMessage = receivedMessages[][0]
    check:
      receivedMessage.data == testData
      receivedMessage.fromPeer.data.len == 0
      receivedMessage.seqno.len == 0
      receivedMessage.signature.len == 0
      receivedMessage.key.len == 0

  type NodeConfig = object
    sign: bool
    verify: bool
    anonymize: bool

  type Scenario = object
    senderConfig: NodeConfig
    receiverConfig: NodeConfig
    shouldWork: bool

  let scenarios: seq[Scenario] =
    @[
      # valid combos
      # S default, R default
      Scenario(
        senderConfig: NodeConfig(sign: true, verify: true, anonymize: false),
        receiverConfig: NodeConfig(sign: true, verify: true, anonymize: false),
        shouldWork: true,
      ),
      # S default, R anonymous
      Scenario(
        senderConfig: NodeConfig(sign: true, verify: true, anonymize: false),
        receiverConfig: NodeConfig(sign: false, verify: false, anonymize: true),
        shouldWork: true,
      ),
      # S anonymous, R anonymous
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: false, anonymize: true),
        receiverConfig: NodeConfig(sign: false, verify: false, anonymize: true),
        shouldWork: true,
      ),
      # S only sign, R only verify
      Scenario(
        senderConfig: NodeConfig(sign: true, verify: false, anonymize: false),
        receiverConfig: NodeConfig(sign: false, verify: true, anonymize: false),
        shouldWork: true,
      ),
      # S only verify, R only sign
      Scenario(
        senderConfig: NodeConfig(sign: true, verify: true, anonymize: true),
        receiverConfig: NodeConfig(sign: false, verify: false, anonymize: false),
        shouldWork: true,
      ),
      # S anonymous (not signed despite the flag), R minimal
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: true, anonymize: true),
        receiverConfig: NodeConfig(sign: true, verify: false, anonymize: false),
        shouldWork: true,
      ),
      # S unsigned, R unsigned
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: false, anonymize: false),
        receiverConfig: NodeConfig(sign: false, verify: false, anonymize: false),
        shouldWork: true,
      ),

      # invalid combos
      # S anonymous, R default
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: false, anonymize: true),
        receiverConfig: NodeConfig(sign: true, verify: true, anonymize: false),
        shouldWork: false,
      ),
      # S unsigned, R anonymous but verify 
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: false, anonymize: false),
        receiverConfig: NodeConfig(sign: true, verify: true, anonymize: true),
        shouldWork: false,
      ),
      # S unsigned, R default
      Scenario(
        senderConfig: NodeConfig(sign: false, verify: false, anonymize: false),
        receiverConfig: NodeConfig(sign: true, verify: true, anonymize: false),
        shouldWork: false,
      ),
    ]

  for scenario in scenarios:
    let title = "Compatibility matrix: " & $scenario
    asyncTest title:
      let
        sender = generateNodes(
          1,
          gossip = true,
          sign = scenario.senderConfig.sign,
          verifySignature = scenario.senderConfig.verify,
          anonymize = scenario.senderConfig.anonymize,
        )[0]
        receiver = generateNodes(
          1,
          gossip = true,
          sign = scenario.receiverConfig.sign,
          verifySignature = scenario.receiverConfig.verify,
          anonymize = scenario.receiverConfig.anonymize,
        )[0]
        nodes = @[sender, receiver]

      startNodesAndDeferStop(nodes)
      await connectNodesStar(nodes)

      let (messageReceivedFut, handler) = createCompleteHandler()

      nodes.subscribeAllNodes(topic, handler)
      await waitForHeartbeat()

      discard await sender.publish(topic, testData)

      let messageReceived = await waitForState(messageReceivedFut, HEARTBEAT_TIMEOUT)
      check:
        if scenario.shouldWork:
          messageReceived.isCompleted(true)
        else:
          messageReceived.isCancelled()
