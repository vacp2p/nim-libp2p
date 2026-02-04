# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, sequtils
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extensions, gossipsub/extensions_types, rpc/messages]
import ../../../tools/[unittest, crypto]
import ./extension_recording

proc makeRPC(extensions: ControlExtensions = ControlExtensions()): RPCMsg =
  RPCMsg(control: some(ControlMessage(extensions: some(extensions))))

proc createMisbehaveProc*(): (ref seq[PeerId], OnMisbehaveProc) =
  let peers = new seq[PeerId]
  peers[] = @[]

  let cb: OnMisbehaveProc = proc(peerId: PeerId) {.closure, gcsafe.} =
    peers[].add(peerId)

  (peers, cb)

suite "GossipSub Extensions :: State":
  let peerId = PeerId.random(rng).get()

  test "default unconfigured state":
    var state = ExtensionsState.new()

    # call all proc, that are called from gossipsub here.
    # by calling these test can't assert much, but it should
    # not cause tests to fail.
    state.handleRPC(peerId, RPCMsg())
    state.addPeer(peerId)
    state.addPeer(peerId)
    state.handleRPC(peerId, makeRPC())
    state.removePeer(peerId)
    state.removePeer(peerId)
    state.heartbeat()
    state.heartbeat()

    # procs that return value should return default value
    check state.makeControlExtensions() == ControlExtensions()
    check state.peerRequestsPartial(peerId, "logos") == false

  test "publishPartial fails when extensions is not configured":
    var state = ExtensionsState.new()
    expect AssertionDefect:
      discard state.publishPartial("logos", nil)

  test "state reports misbehaving when ControlExtensions more then once":
    var (reportedPeers, onMisbehave) = createMisbehaveProc()
    var state = ExtensionsState.new(onMisbehave)

    # peer sends ControlExtensions for the first time
    state.handleRPC(peerId, makeRPC())

    # when peer sends ControlExtensions after that, misbehavior should be reported
    for i in 1 ..< 5:
      state.handleRPC(peerId, makeRPC())
      check reportedPeers[] == repeat[PeerId](peerId, i)

  test "state reports misbehaving when ControlExtensions more then once - many peers reported":
    var (reportedPeers, onMisbehave) = createMisbehaveProc()
    var state = ExtensionsState.new(onMisbehave)

    var peers = newSeq[PeerId]()
    for i in 0 ..< 5:
      let pid = PeerId.random(rng).get()
      state.handleRPC(pid, makeRPC())
      state.handleRPC(pid, makeRPC())
      peers.add(pid)

      check reportedPeers[] == peers

  test "peer is removed":
    var (reportedPeers, onMisbehave) = createMisbehaveProc()
    var state = ExtensionsState.new(onMisbehave)

    for i in 0 ..< 5:
      let pid = PeerId.random(rng).get()
      state.handleRPC(pid, makeRPC())

      # when peer is removed state is cleared, so second handleRPC()
      # call will not cause misbehavior
      state.removePeer(pid)
      state.handleRPC(pid, makeRPC())

      check reportedPeers[].len == 0

  test "state calls all extensions callbacks":
    var ext = RecordingExtension()
    var state = ExtensionsState.new(externalExtensions = @[Extension(ext)])

    # assert that onHeartbeat is called
    state.heartbeat()
    check ext.heartbeatCount == 1
    state.heartbeat()
    check ext.heartbeatCount == 2

    # assert that onNegotiated is not called (ControlExtensions is empty)
    state.handleRPC(peerId, makeRPC(ControlExtensions()))
    check ext.handledRPC.len == 1
    check ext.negotiatedPeers.len == 0
    state.addPeer(peerId)
    check ext.negotiatedPeers.len == 0

    # assert that onNegotiated is not called (testExtension is false)
    state.handleRPC(peerId, makeRPC(ControlExtensions(testExtension: some(false))))
    check ext.handledRPC.len == 2
    check ext.negotiatedPeers.len == 0
    state.addPeer(peerId)
    check ext.negotiatedPeers.len == 0

    # assert that onNegotiated is called (handleRPC, then addPeer)
    let peerId1 = PeerId.random(rng).get()
    state.handleRPC(peerId1, makeRPC(ControlExtensions(testExtension: some(true))))
    check ext.handledRPC.len == 3
    check ext.negotiatedPeers.len == 0
    state.addPeer(peerId1)
    check ext.negotiatedPeers == @[peerId1]

    # assert that onNegotiated is called (addPeer, then handleRPC)
    let peerId2 = PeerId.random(rng).get()
    state.addPeer(peerId2)
    check ext.negotiatedPeers.len == 1
    state.handleRPC(peerId2, makeRPC(ControlExtensions(testExtension: some(true))))
    check ext.handledRPC.len == 4
    check ext.negotiatedPeers == @[peerId1, peerId2]

    # assert that onRemovePeer is called
    state.removePeer(peerId1)
    state.removePeer(peerId2)
    check ext.removedPeers == @[peerId1, peerId2]
