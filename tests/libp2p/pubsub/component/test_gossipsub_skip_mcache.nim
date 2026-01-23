# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, stew/byteutils
import ../../../../libp2p/protocols/pubsub/[gossipsub, peertable, rpc/messages]
import ../../../tools/[unittest]
import ../utils

suite "GossipSub Component - Skip MCache Support":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "publish with skipMCache prevents message from being added to mcache":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = some(PublishParams(skipMCache: true))
    ), 1

    check:
      nodes[0].mcache.msgs.len == 0

  asyncTest "publish without skipMCache adds message to mcache":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = none(PublishParams)
    ), 1

    check:
      nodes[0].mcache.msgs.len == 1
