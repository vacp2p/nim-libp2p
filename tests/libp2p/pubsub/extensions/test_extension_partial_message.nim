# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extension_partial_message, gossipsub/extensions_types, rpc/messages]
import ../../../tools/[unittest]

proc setupConfig(): PartialMessageExtensionConfig =
  proc sendRPC(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].} =
    discard

  proc publishToPeers(topic: string): seq[PeerId] {.gcsafe, raises: [].} =
    return newSeq[PeerId]()

  proc nodeTopicOpts(topic: string): TopicOpts {.gcsafe, raises: [].} =
    return TopicOpts()

  proc isSupportedCb(peer: PeerId): bool {.gcsafe, raises: [].} =
    return true

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    ok()

  proc onIncomingRPC(
      peer: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    discard

  return PartialMessageExtensionConfig(
    sendRPC: sendRPC,
    publishToPeers: publishToPeers,
    isSupported: isSupportedCb,
    nodeTopicOpts: nodeTopicOpts,
    validateRPC: validateRPC,
    onIncomingRPC: onIncomingRPC,
    heartbeatsTillEviction: 3,
  )

suite "GossipSub Extensions :: Partial Message Extension":
  test "isSupported":
    let ext = PartialMessageExtension.new()
    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(partialMessageExtension: true)) == true

  test "config validation":
    expect AssertionDefect:
      let ext = PartialMessageExtension.new(PartialMessageExtensionConfig())

    expect AssertionDefect:
      var config = setupConfig()
      config.sendRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.publishToPeers = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.isSupported = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.nodeTopicOpts = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.validateRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.onIncomingRPC = nil
      let ext = PartialMessageExtension.new(config)

    expect AssertionDefect:
      var config = setupConfig()
      config.heartbeatsTillEviction = 0
      let ext = PartialMessageExtension.new(config)
