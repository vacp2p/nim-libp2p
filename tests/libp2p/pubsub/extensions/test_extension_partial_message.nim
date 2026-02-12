# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, tables, results, strutils, stew/byteutils, sequtils
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extension_partial_message, gossipsub/extensions_types, rpc/messages]
import ../../../tools/[unittest, crypto]
import ./my_partial_message

proc isPartialTopic(topic: string): bool =
  # convention: in this test file, topics that have "partial" in their name will be considered
  # to be requesting partial messages
  return topic.contains("partial")

type PeerRPC = object
  peerId: PeerId # who sent RPC or to whom RPC was sent to (depending on usage)
  rpc: PartialMessageExtensionRPC

type CallbackRecorder = ref object
  publishToPeers: seq[PeerId]
  sentRPC: seq[PeerRPC] # peerId - to whom PRC was sent to
  incomingRPC: seq[PeerRPC] # peerId - who sent RPC

proc config(c: CallbackRecorder): PartialMessageExtensionConfig =
  proc sendRPC(peerId: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].} =
    c.sentRPC.add(PeerRPC(peerId: peerId, rpc: rpc))

  proc publishToPeers(topic: string): seq[PeerId] {.gcsafe, raises: [].} =
    return c.publishToPeers

  proc nodeTopicOpts(topic: string): TopicOpts {.gcsafe, raises: [].} =
    return TopicOpts(requestsPartial: isPartialTopic(topic))

  proc isSupported(peer: PeerId): bool {.gcsafe, raises: [].} =
    return true

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    checkLen(rpc.partsMetadata)
    return ok()

  proc onIncomingRPC(
      peerId: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    c.incomingRPC.add(PeerRPC(peerId: peerId, rpc: rpc))

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
            requestsPartial: some(isPartialTopic(topic)),
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
  let groupId = "group-id-1".toBytes

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
      config.unionPartsMetadata = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = cr.config()
      config.heartbeatsTillEviction = 0
      let ext = PartialMessageExtension.new(config)

  test "subscribe/unsubscribe":
    const topicPartial = "logos-partial"
    const topicFull = "logos-full"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    # should subscribe with requesting partial
    check ext.peerRequestsPartial(peerId, topicPartial) == false
    ext.subscribe(peerId, topicPartial, true)
    check ext.peerRequestsPartial(peerId, topicPartial)

    # unsubscribe should remove information about this topic
    ext.subscribe(peerId, topicPartial, false)
    check ext.peerRequestsPartial(peerId, topicPartial) == false

    # unsubscribe same peer again (should not raise)
    ext.subscribe(peerId, topicPartial, false)

    # should subscribe without partial
    check ext.peerRequestsPartial(peerId, topicFull) == false
    ext.subscribe(peerId, topicFull, true)
    check ext.peerRequestsPartial(peerId, topicFull) == false

    # when peer is removed there should not be any data associated with them
    ext.subscribe(peerId, topicPartial, true)
    ext.onRemovePeer(peerId)
    check ext.peerRequestsPartial(peerId, topicPartial) == false

    # remove same peer again (should not raise)
    ext.onRemovePeer(peerId)

  test "RPC validation":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    # invalid RPC case
    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: @[1.byte] # invalid metadata
      ),
    )
    check cr.incomingRPC.len == 0 # should not call onIncomingRPC

    # valid RPC case
    let pmRPC = PartialMessageExtensionRPC(
      topicID: topic, groupID: groupId, partsMetadata: MyPartsMetadata.want(@[1, 2])
    )
    ext.handlePartialMessage(peerId, pmRPC)
    check:
      cr.incomingRPC.len == 1 # should call onIncomingRPC
      cr.incomingRPC[0] == PeerRPC(peerId: peerId, rpc: pmRPC)

  test "publish partial message: to all in topic advertizing parts":
    # the usecase when application is publishing partial message to all peers subscribed on topic.
    # and since no peer has asked for any part in particular, only parts metadata are being sent.
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    # peer subscribes with partial capability
    ext.subscribe(peerId, topic, true)

    # application/user is publishing message with parts [1, 2, 3]
    let pm = MyPartialMessage(
      groupId: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    check ext.publishPartial(topic, pm) == 1 # should publish to one peer

    # the peer should receive partial messages RPC 
    check:
      cr.sentRPC.len == 1
      cr.sentRPC[0] ==
        PeerRPC(
          peerId: peerId,
          rpc: PartialMessageExtensionRPC(
            groupID: groupId,
            topicID: topic,
            partsMetadata: MyPartsMetadata.have(@[1, 2, 3]),
              # only metadata are sent because peer has not asked for any parts
          ),
        )

    # publishing same message again should not send to peer
    # because peer has already received same parts metadata
    check ext.publishPartial(topic, pm) == 0
    check cr.sentRPC.len == 1

  test "publish partial message: selected peers filling request":
    # usecase when application sends partial message to peer in response to their seeking request.
    # application only pushes partial message to selected peer (peer that was seeking parts).
    # this test can be seen as continuation of test above. consider full usecase:
    # - precondition: all nodes have all parts
    # - node A: publishes new message (eagerly advertizing new parts)
    # - node B: receives metadata (this is where first test ends)
    # - node B: requests missing parts  
    # - node A: fulfills request sending message only to node B (this is where second test, this test, ends)
    const topic = "logos-partial"
    var cr = CallbackRecorder(
      publishToPeers:
        @[peerId]
          # note: this list of peers that we publish by default, 
          # but in this test we ignore those and publish to selected peers
    )
    var ext = PartialMessageExtension.new(cr.config())
    let selectedPeerId = PeerId.random(rng).get()

    # must subscribe all peers with partial capability
    ext.subscribe(peerId, topic, true)
    ext.subscribe(selectedPeerId, topic, true)

    # selected peer sends RPC seeking parts [1, 2]
    ext.handlePartialMessage(
      selectedPeerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: MyPartsMetadata.want(@[1, 2])
      ),
    )

    # application/user is publishing message with parts [1, 2, 3] to selected peer
    let pm = MyPartialMessage(
      groupId: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    check ext.publishPartial(topic, pm, peers = @[selectedPeerId]) == 1
      # should publish to selected peer

    # the selected peer should receive partial messages RPC
    check:
      cr.sentRPC.len == 1
      cr.sentRPC[0] ==
        PeerRPC(
          peerId: selectedPeerId, # selected peer receives rpc
          rpc: PartialMessageExtensionRPC(
            groupID: groupId,
            topicID: topic,
            partialMessage: "onetwo".toBytes,
              # only parts [1, 2] are sent as those were requested
              # and part [3] is ignored
            partsMetadata: MyPartsMetadata.have(@[1, 2, 3]),
              # but peer receives all parts metadata because it was never sent to them
          ),
        )

    # publishing same message again should not send to peer
    # because peer's request is already fulfilled
    check ext.publishPartial(topic, pm, peers = @[selectedPeerId]) == 0
    check cr.sentRPC.len == 1

  test "publish parts metadata":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    ext.subscribe(peerId, topic, true)

    # should publish to peer because peer is subscribed
    # and because we are sending new parts metadata
    let pm = MyPartialMessage(groupId: groupId, data: {1: "one".toBytes}.toTable)
    check ext.publishPartial(topic, pm) == 1

    check:
      cr.sentRPC.len == 1
      cr.sentRPC[0] ==
        PeerRPC(
          peerId: peerId,
          rpc: PartialMessageExtensionRPC(
            groupID: groupId, topicID: topic, partsMetadata: pm.partsMetadata()
          ),
        )

    # publishing same message again should not publish
    # because peer already has this parts metadata
    check ext.publishPartial(topic, pm) == 0
    check cr.sentRPC.len == 1

    # publishing new partial message should send new parts metadata
    let pm2 = MyPartialMessage(groupId: groupId, data: {2: "two".toBytes}.toTable)
    check ext.publishPartial(topic, pm2) == 1
    check:
      cr.sentRPC.len == 2
      cr.sentRPC[1].rpc ==
        PartialMessageExtensionRPC(
          groupID: groupId,
          topicID: topic,
          partsMetadata: pm.partsMetadata() & pm2.partsMetadata(),
        )

  test "heartbeat evicts metadata":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    ext.subscribe(peerId, topic, true)

    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: MyPartsMetadata.want(@[1])
      ),
    )

    # trigger as many heartbeat events to cause eviction of all state groups
    for i in 0 ..< cr.config().heartbeatsTillEviction + 1:
      ext.onHeartbeat()

    # should publish to peer because peer is still subscribed
    # and because we are sending new partsMetadata.
    let pm = MyPartialMessage(groupId: groupId, data: {1: "one".toBytes}.toTable)
    check ext.publishPartial(topic, pm) == 1

    # but published rpc should not have partial message only parts metadata
    check cr.sentRPC.len == 1
    let msg1 = cr.sentRPC[0].rpc
    check:
      msg1.topicID == topic
      msg1.groupID == groupId
      msg1.partialMessage.len == 0
      msg1.partsMetadata.len > 0

  test "removing peer removes metadata":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    ext.subscribe(peerId, topic, true)

    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: MyPartsMetadata.want(@[1])
      ),
    )

    # when peer is removed, its parts metadata will be removed
    ext.onRemovePeer(peerId)

    # should not publish to peer because metadata has been removed
    let pm = MyPartialMessage(groupId: groupId, data: {1: "one".toBytes}.toTable)
    check ext.publishPartial(topic, pm) == 0

  test "publishPartial and onIncomingRPC are not called when groupId is not set":
    const topic = "logos-partial"
    var cr = CallbackRecorder(publishToPeers: @[peerId])
    var ext = PartialMessageExtension.new(cr.config())

    ext.subscribe(peerId, topic, true)

    # should not call onIncomingRPC, groupID is not set
    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, partsMetadata: MyPartsMetadata.want(@[1, 2])
      ),
    )
    check cr.incomingRPC.len == 0

    # should call onIncomingRPC, groupID is set
    ext.handlePartialMessage(
      peerId,
      PartialMessageExtensionRPC(
        topicID: topic, groupID: groupId, partsMetadata: MyPartsMetadata.want(@[1, 2])
      ),
    )
    check cr.incomingRPC.len == 1

    # should not publish when groupId is not set
    var pm = MyPartialMessage(
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable
    )
    check ext.publishPartial(topic, pm) == 0

    # should publish with groupId
    pm.groupId = groupId
    check ext.publishPartial(topic, pm) == 1

  test "gossip metadata":
    const topic = "logos-partial"
    var cr = CallbackRecorder()
    var cfg = cr.config()
    cfg.heartbeatsTillEviction = 100 # do not evict for this test
    var ext = PartialMessageExtension.new(cfg)

    # publishing a partial message will store the parts metadata.
    # however, since no one is subscribed, nothing will actually be published.
    let pm = MyPartialMessage(
      groupId: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    check ext.publishPartial(topic, pm) == 0
    check cr.sentRPC.len == 0

    # subscribe peer to topic (requesting partial).
    ext.subscribe(peerId, topic, true)

    # then when gossip happens (on heartbeat), parts metadata 
    # should be sent to all peers.
    ext.onHeartbeat()

    # and because peer has requested partial messages, then
    # it will receive gossip message.
    check:
      cr.sentRPC.len == 1
      cr.sentRPC[0].rpc ==
        PartialMessageExtensionRPC(
          topicID: topic,
          groupID: groupId,
          partsMetadata: MyPartsMetadata.have(toSeq(pm.data.keys)),
        )

    # doing gossip again should not send any new messages,
    # because peer already knows the same parts metadata.
    ext.onHeartbeat()
    check cr.sentRPC.len == 1
