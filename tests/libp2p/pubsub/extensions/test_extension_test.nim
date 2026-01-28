# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options
import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/extensions, rpc/messages]
import ../../../tools/[unittest, crypto]
import ../utils

proc makeRPC(extensions: ControlExtensions = ControlExtensions()): RPCMsg =
  RPCMsg(control: some(ControlMessage(extensions: some(extensions))))

suite "GossipSub Extensions :: Test Extension":
  let peerId = PeerId.random(rng).get()

  test "extension is configured, peer is not supporting":
    var
      (reportedPeers, onMissbehave) = createCollectPeerCallback()
      (negotiatedPeers, onNegotiated) = createCollectPeerCallback()
      (handleRPCPeers, onHandleRPC) = createCollectPeerCallback()
      ext = TestExtensionConfig(onNegotiated: onNegotiated, onHandleRPC: onHandleRPC)

    # negotiated in order: handleRPC, addPeer
    state.handleRPC(peerId, makeRPC())
    state.addPeer(peerId)
    check:
      reportedPeers[].len == 0
      negotiatedPeers[].len == 0
      handleRPCPeers[].len == 0

    # negotiated in order: addPeer, handleRPC
    state = ExtensionsState.new(
      onMissbehave,
      some(TestExtensionConfig(onNegotiated: onNegotiated, onHandleRPC: onHandleRPC)),
    )
    state.addPeer(peerId)
    state.handleRPC(peerId, makeRPC())
    check:
      reportedPeers[].len == 0
      negotiatedPeers[].len == 0
      handleRPCPeers[].len == 0

  test "extension is configured, peer is supporting":
    test "node receives rpc then adds peer":
      var
        (reportedPeers, onMissbehave) = createCollectPeerCallback()
        (negotiatedPeers, onNegotiated) = createCollectPeerCallback()
        (handleRPCPeers, onHandleRPC) = createCollectPeerCallback()
        state = ExtensionsState.new(
          onMissbehave,
          some(
            TestExtensionConfig(onNegotiated: onNegotiated, onHandleRPC: onHandleRPC)
          ),
        )

      state.handleRPC(peerId, makeRPC(ControlExtensions(testExtension: some(true))))
      check:
        reportedPeers[].len == 0
        negotiatedPeers[].len == 0
        handleRPCPeers[] == @[peerId]

      state.addPeer(peerId)
      check:
        reportedPeers[].len == 0
        negotiatedPeers[] == @[peerId]
        handleRPCPeers[] == @[peerId]

    test "node adds peer then receives rpc":
      var
        (reportedPeers, onMissbehave) = createCollectPeerCallback()
        (negotiatedPeers, onNegotiated) = createCollectPeerCallback()
        (handleRPCPeers, onHandleRPC) = createCollectPeerCallback()
        state = ExtensionsState.new(
          onMissbehave,
          some(
            TestExtensionConfig(onNegotiated: onNegotiated, onHandleRPC: onHandleRPC)
          ),
        )

      state.addPeer(peerId)
      check:
        reportedPeers[].len == 0
        negotiatedPeers[].len == 0
        handleRPCPeers[].len == 0

      state.handleRPC(peerId, makeRPC(ControlExtensions(testExtension: some(true))))
      check:
        reportedPeers[].len == 0
        negotiatedPeers[] == @[peerId]
        handleRPCPeers[] == @[peerId]
