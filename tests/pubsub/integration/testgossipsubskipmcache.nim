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
import ../../../libp2p/protocols/pubsub/[gossipsub, peertable, pubsubpeer]
import ../../../libp2p/protocols/pubsub/rpc/[messages]
import ../../helpers

suite "GossipSub Integration - Skip MCache Support":
  teardown:
    checkTrackers()

  asyncTest "publish with skipMCache prevents message from being added to mcache":
    let
      topic = "test"
      handler = proc(topic: string, data: seq[byte]) {.async.} =
        discard
      nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    await waitSub(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()

    let msgId = GossipSub(nodes[0]).getMsgId(topic, publishData)

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = some(PublishParams(useCustomConn: true))
    ), 1

    check msgId notin GossipSub(nodes[0]).mcache.msgs

  asyncTest "publish without skipMCache adds message to mcache":
    let
      topic = "test"
      handler = proc(topic: string, data: seq[byte]) {.async.} =
        discard
      nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    await waitSub(nodes[0], nodes[1], topic)

    let publishData = "hello".toBytes()
    let msgId = GossipSub(nodes[0]).getMsgId(topic, publishData)

    tryPublish await nodes[0].publish(
      topic, publishData, publishParams = none(PublishParams)
    ), 1

    check msgId in GossipSub(nodes[0]).mcache.msgs
