# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, results, options
import ../../../libp2p/peerid
import ../../../libp2p/protocols/pubsub/gossipsub/extensions
import ../../../libp2p/protocols/pubsub/rpc/messages
import ../../tools/[unittest, crypto]

proc createCountPeerCallback(): (ref int, PeerCallback) =
  let counter = new int
  counter[] = 0

  let cb: PeerCallback = proc (peerId: PeerId) {.closure, gcsafe.} =
    inc counter[]

  (counter, cb)


suite "GossipSub Extensions":
  let peerId = PeerId.random(rng).get()

  test "default unconfigured state":
    # tets does not assert anything explictly, but it should not crash
    # when unconfigured state is used
    var state = ExtensionsState.new()
    state.handleRPC(peerId, ControlExtensions())
    state.addPeer(peerId)
    state.handleRPC(peerId, ControlExtensions())
    state.removePeer(peerId)

  test "state reports missbehaving":
    var (reportCount, onMissbehave) = createCountPeerCallback()
    
    var state = ExtensionsState.new(onMissbehave)

    # peer sends ControlExtensions for the first time
    state.handleRPC(peerId, ControlExtensions())
    
    # when peer sends ControlExtensions after that, missbehavior should be reported
    for i in 1 ..< 5:
      state.handleRPC(peerId, ControlExtensions())
      check reportCount[] == i

  test "testExtensions - extension is configured, peer is not supporting":
    var (reportCount, onMissbehave) = createCountPeerCallback()
    var (nagotiatedCount, onNagotiated) = createCountPeerCallback()
    var (handleRPCCount, onHandleRPC) = createCountPeerCallback()

    var state = ExtensionsState.new(onMissbehave, some(TestExtensionConfig.new(onNagotiated, onHandleRPC)))

    # nagotiated in order: handleRPC, addPeer
    state.handleRPC(peerId, ControlExtensions())
    state.addPeer(peerId)
    check:
      reportCount[] == 0
      nagotiatedCount[] == 0
      handleRPCCount[] == 0
    
    # nagotiated in order: addPeer, handleRPC
    state = ExtensionsState.new(onMissbehave, some(TestExtensionConfig.new(onNagotiated, onHandleRPC)))
    state.addPeer(peerId)
    state.handleRPC(peerId, ControlExtensions())
    check:
      reportCount[] == 0
      nagotiatedCount[] == 0
      handleRPCCount[] == 0

  test "testExtensions - extension is configured, peer is supporting":
    test "node receives rpc then adds peer":
      var (reportCount, onMissbehave) = createCountPeerCallback()
      var (nagotiatedCount, onNagotiated) = createCountPeerCallback()
      var (handleRPCCount, onHandleRPC) = createCountPeerCallback()
      var state = ExtensionsState.new(onMissbehave, some(TestExtensionConfig.new(onNagotiated, onHandleRPC)))

      state.handleRPC(peerId, ControlExtensions(testExtension: some(true)))
      check:
        reportCount[] == 0
        nagotiatedCount[] == 0
        handleRPCCount[] == 1

      state.addPeer(peerId)
      check:
        reportCount[] == 0
        nagotiatedCount[] == 1
        handleRPCCount[] == 1
    
    test "node adds peer then receives rpc":
      var (reportCount, onMissbehave) = createCountPeerCallback()
      var (nagotiatedCount, onNagotiated) = createCountPeerCallback()
      var (handleRPCCount, onHandleRPC) = createCountPeerCallback()
      var state = ExtensionsState.new(onMissbehave, some(TestExtensionConfig.new(onNagotiated, onHandleRPC)))

      state.addPeer(peerId)
      check:
        reportCount[] == 0
        nagotiatedCount[] == 0
        handleRPCCount[] == 0
        
      state.handleRPC(peerId, ControlExtensions(testExtension: some(true)))
      check:
        reportCount[] == 0
        nagotiatedCount[] == 1
        handleRPCCount[] == 1
    