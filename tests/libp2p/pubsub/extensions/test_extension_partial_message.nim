# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, tables, results, strutils
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/[
    gossipsub/extension_partial_message,
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
    return TopicOpts(requestsPartial: topic.contains("partial"))
      # convention, in this test file, topic that have "partial" in name will be consider 
      # to be requesting partial messages

  proc isSupported(peer: PeerId): bool {.gcsafe, raises: [].} =
    return true

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
    unionPartsMetadata: my_partial_message.unionPartsMetadata,
    validateRPC: validateRPC,
    onIncomingRPC: onIncomingRPC,
    heartbeatsTillEviction: 3,
  )

proc subscribe(
    ext: PartialMessageExtension, peerId: PeerId, topic: string, subscribe: bool
) =
  # helper utility for subscribing
  ext.onHandleRPC(
    peerId,
    RPCMsg(
      subscriptions:
        @[
          SubOpts(
            topic: topic,
            subscribe: subscribe,
            requestsPartial: some(topic.contains("partial")),
          )
        ]
    ),
  )

proc handlePartialMessage(
    ext: PartialMessageExtension, peerId: PeerId, rpc: PartialMessageExtensionRPC
) =
  ext.onHandleRPC(peerId, RPCMsg(partialMessageExtension: some(rpc)))

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

    # peer subscribes with partial capability (topic has 'partial')
    ext.subscribe(peerId, topic, true)
    check ext.peerRequestsPartial(peerId, topic)

    # peer sends RPC seeking parts [1, 2]
    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: rawMetadata(@[1, 2], Meta.want)
      ),
    )

    # application/user is publishing message with parts [1, 2, 3]
    let pm = MyPartialMessage(
      groupId: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    check ext.publishPartial(topic, pm) == 1 # should publish to one peer

    # the peer should receive partial messages RPC with data of parts [1, 2] = "one" + "two"
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
