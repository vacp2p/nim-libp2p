# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, sequtils
import ../../../libp2p/peerid
import ../../../libp2p/protocols/pubsub/[gossipsub/extensions, rpc/messages]
import ../../tools/[unittest, crypto]
import ./utils

suite "GossipSub Extensions":
  let peerId = PeerId.random(rng).get()

  test "state":
    # holds tests about ExtensionsState general functionality

    test "default unconfigured state":
      # test does not assert anything explictly, but it should not crash
      # when unconfigured state is used
      var state = ExtensionsState.new()
      state.handleRPC(peerId, ControlExtensions())
      state.addPeer(peerId)
      state.addPeer(peerId)
      state.handleRPC(peerId, ControlExtensions())
      state.removePeer(peerId)
      state.removePeer(peerId)

    test "state reports missbehaving":
      var (reportedPeers, onMissbehave) = createCollectPeerCallback()
      var state = ExtensionsState.new(onMissbehave)

      # peer sends ControlExtensions for the first time
      state.handleRPC(peerId, ControlExtensions())

      # when peer sends ControlExtensions after that, missbehavior should be reported
      for i in 1 ..< 5:
        state.handleRPC(peerId, ControlExtensions())
        check reportedPeers[] == repeat[PeerId](peerId, i)

    test "state reports missbehaving - many peers":
      var (reportedPeers, onMissbehave) = createCollectPeerCallback()
      var state = ExtensionsState.new(onMissbehave)

      var peers = newSeq[PeerId]()
      for i in 0 ..< 5:
        let pid = PeerId.random(rng).get()
        state.handleRPC(pid, ControlExtensions())
        state.handleRPC(pid, ControlExtensions())
        peers.add(pid)

        check reportedPeers[] == peers

    test "state peer is removed":
      var (reportedPeers, onMissbehave) = createCollectPeerCallback()
      var state = ExtensionsState.new(onMissbehave)

      for i in 0 ..< 5:
        let pid = PeerId.random(rng).get()
        state.handleRPC(pid, ControlExtensions())

        # when peer is removed state is cleared, so second handleRPC()
        # call will not cause missbehaviour
        state.removePeer(pid)
        state.handleRPC(pid, ControlExtensions())

        check reportedPeers[].len == 0

  test "testExtension":
    # test holds all tests related to "Test Extension"

    test "extension is configured, peer is not supporting":
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

      # negotiated in order: handleRPC, addPeer
      state.handleRPC(peerId, ControlExtensions())
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
      state.handleRPC(peerId, ControlExtensions())
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

        state.handleRPC(peerId, ControlExtensions(testExtension: some(true)))
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

        state.handleRPC(peerId, ControlExtensions(testExtension: some(true)))
        check:
          reportedPeers[].len == 0
          negotiatedPeers[] == @[peerId]
          handleRPCPeers[] == @[peerId]
