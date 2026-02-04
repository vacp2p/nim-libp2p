# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, tables, results, strutils
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/[
    gossipsub/extension_partial_message,
    gossipsub/partial_message,
    gossipsub/extensions_types,
    rpc/messages,
  ]
import ../../../tools/[unittest, crypto]
import ./my_partial_message

type CallbackRecorder = ref object
  publishToPeers: seq[PeerId]
  sentRPC: seq[PartialMessageExtensionRPC]
  incomingRPC: seq[PartialMessageExtensionRPC]

proc config(c: CallbackRecorder): PartialMessageExtensionConfig =
  proc sendRPC(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].} =
    c.sentRPC.add(rpc)

  proc publishToPeers(topic: string): seq[PeerId] {.gcsafe, raises: [].} =
    return c.publishToPeers

  proc nodeTopicOpts(topic: string): TopicOpts {.gcsafe, raises: [].} =
    if topic.contains("partial"):
      return TopicOpts(requestsPartial: true)
    return TopicOpts()

  proc isSupported(peer: PeerId): bool {.gcsafe, raises: [].} =
    return true

  proc unionPartsMetadataCb(
      a, b: PartsMetadata
  ): Result[PartsMetadata, string] {.gcsafe, raises: [].} =
    return unionPartsMetadata(a, b)

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    checkLen(rpc.partsMetadata)
    return ok()

  proc onIncomingRPC(
      peer: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    c.incomingRPC.add(rpc)

  return PartialMessageExtensionConfig(
    sendRPC: sendRPC,
    publishToPeers: publishToPeers,
    isSupported: isSupported,
    nodeTopicOpts: nodeTopicOpts,
    unionPartsMetadata: unionPartsMetadataCb,
    validateRPC: validateRPC,
    onIncomingRPC: onIncomingRPC,
    heartbeatsTillEviction: 3,
  )

suite "GossipSub Extensions :: Partial Message Extension":
  let peerId = PeerId.random(rng).get()
  let groupId = @[1.byte, 1, 1, 1, 1]

  test "isSupported":
    let ext = PartialMessageExtension.new()
    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(partialMessageExtension: true)) == true

  test "config validation":
    var cr = CallbackRecorder()

    expect AssertionDefect:
      let ext = PartialMessageExtension.new(PartialMessageExtensionConfig())

    expect AssertionDefect:
      var config = cr.config()
      config.sendRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.publishToPeers = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.isSupported = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.nodeTopicOpts = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.validateRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.onIncomingRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.heartbeatsTillEviction = 0
      let ext = PartialMessageExtension.new(config)

  test "publish partial":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    # subscribe peer
    ext.onHandleRPC(
      peerId,
      RPCMsg(
        subscriptions:
          @[SubOpts(topic: topic, subscribe: true, requestsPartial: some(true))]
      ),
    )
    check ext.peerRequestsPartial(peerId, topic)

    # peer sends RPC seeking parts 1, 2
    ext.onHandleRPC(
      peerId,
      RPCMsg(
        partialMessageExtension: some(
          PartialMessageExtensionRPC(
            topicID: topic,
            groupID: groupId,
            partsMetadata: rawMetadata(@[1, 2], Meta.want),
          )
        )
      ),
    )

    let pm = MyPartialMessage(
      groupId: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    check ext.publishPartial(topic, pm) == 1 # should publish to one peer

    check cr.sentRPC.len == 1
    let msg1 = cr.sentRPC[0]
    check:
      msg1.topicID == topic
      msg1.groupID == groupId
      msg1.partialMessage == "onetwo".toBytes

    # publishing same message again should not send to peer 
    # because peer's request is already fulfilled
    check ext.publishPartial(topic, pm) == 0
    check cr.sentRPC.len == 1
