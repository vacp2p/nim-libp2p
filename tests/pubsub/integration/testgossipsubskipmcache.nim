# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import stew/byteutils
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, peertable]
import ../../../libp2p/protocols/pubsub/rpc/[messages]
import ../../helpers

suite "GossipSub Integration - Skip MCache Support":
  teardown:
    checkTrackers()

  asyncTest "publish with skipMCache prevents message from being added to mcache":
    let
      topic = "test"
      nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    await waitSub(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = some(PublishParams(skipMCache: true))
    ), 1

    check:
      nodes[0].mcache.msgs.len == 0

  asyncTest "publish without skipMCache adds message to mcache":
    let
      topic = "test"
      nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    await waitSub(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = none(PublishParams)
    ), 1

    check:
      nodes[0].mcache.msgs.len == 1
