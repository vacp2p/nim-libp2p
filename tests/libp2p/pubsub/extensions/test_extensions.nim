# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, sequtils
import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/extensions, rpc/messages]
import ../../../tools/[unittest, crypto]
import ../utils

proc makeRPC(extensions: ControlExtensions = ControlExtensions()): RPCMsg =
  RPCMsg(control: some(ControlMessage(extensions: some(extensions))))

suite "GossipSub Extensions :: State":
  let peerId = PeerId.random(rng).get()

  test "default unconfigured state":
    # test does not assert anything explicitly, but it should not crash
    # when unconfigured state is used
    var state = ExtensionsState.new()
    state.handleRPC(peerId, RPCMsg())
    state.addPeer(peerId)
    state.addPeer(peerId)
    state.handleRPC(peerId, makeRPC())
    state.removePeer(peerId)
    state.removePeer(peerId)
    state.heartbeat()
    discard state.makeControlExtensions()

  test "state reports missbehaving":
    var (reportedPeers, onMisbehave) = createCollectPeerCallback()
    var state = ExtensionsState.new(onMisbehave)

    # peer sends ControlExtensions for the first time
    state.handleRPC(peerId, makeRPC())

    # when peer sends ControlExtensions after that, missbehavior should be reported
    for i in 1 ..< 5:
      state.handleRPC(peerId, makeRPC())
      check reportedPeers[] == repeat[PeerId](peerId, i)

  test "state reports missbehaving - many peers":
    var (reportedPeers, onMisbehave) = createCollectPeerCallback()
    var state = ExtensionsState.new(onMisbehave)

    var peers = newSeq[PeerId]()
    for i in 0 ..< 5:
      let pid = PeerId.random(rng).get()
      state.handleRPC(pid, makeRPC())
      state.handleRPC(pid, makeRPC())
      peers.add(pid)

      check reportedPeers[] == peers

  test "state peer is removed":
    var (reportedPeers, onMisbehave) = createCollectPeerCallback()
    var state = ExtensionsState.new(onMisbehave)

    for i in 0 ..< 5:
      let pid = PeerId.random(rng).get()
      state.handleRPC(pid, makeRPC())

      # when peer is removed state is cleared, so second handleRPC()
      # call will not cause misbehaviour
      state.removePeer(pid)
      state.handleRPC(pid, makeRPC())

      check reportedPeers[].len == 0

  test "state with callback extensions":
    discard
    # TODO
