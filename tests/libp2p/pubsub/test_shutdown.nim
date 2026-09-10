# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ./utils
import ../../../libp2p/connmanager
import ../../../libp2p/protocols/pubsub/[pubsub, pubsubpeer, floodsub, gossipsub]
import ../../tools/[unittest, switch_builder, bufferstream]

suite "PubSub shutdown":
  teardown:
    checkTrackers()

  asyncTest "switch cancels pubsub connectors before stopping connections":
    let
      sw = makeStandardSwitch()
      gossip = GossipSub.init(sw, rng = rng())
      dialing = newAsyncEvent()
      never = newAsyncEvent()
    var
      attempts = 0
      cancelled = false
      connectionsRunningAtCancellation = false

    proc getStream(): Future[Stream] {.
        async: (raises: [CancelledError, GetStreamDialError])
    .} =
      inc attempts
      dialing.fire()
      try:
        await never.wait()
      finally:
        cancelled = true
        connectionsRunningAtCancellation = sw.connManager.isRunning()

    let peer = PubSubPeer.new(
      randomPeerId(), getStream, nil, GossipSubCodec_12, 1024, voidPeerHandler
    )
    gossip.peers[peer.peerId] = peer
    sw.mount(gossip)
    await sw.start()
    peer.connect()
    await dialing.wait()
    await sw.stop()

    check:
      cancelled
      connectionsRunningAtCancellation
      gossip.peers.len == 0
    peer.connect()
    check attempts == 1
    await peer.stop()

  asyncTest "FloodSub stop cancels peers and rejects late peer events until restart":
    let
      sw = makeStandardSwitch()
      flood = FloodSub.init(sw, rng = rng())
      never = newAsyncEvent()
    var cancelled = false

    proc getStream(): Future[Stream] {.
        async: (raises: [CancelledError, GetStreamDialError])
    .} =
      try:
        await never.wait()
      finally:
        cancelled = true

    let peer = PubSubPeer.new(
      randomPeerId(), getStream, nil, FloodSubCodec, 1024, voidPeerHandler
    )
    flood.peers[peer.peerId] = peer
    await flood.start()
    peer.connect()
    await flood.stop()
    check:
      cancelled
      flood.peers.len == 0
    flood.subscribePeer(randomPeerId())
    check flood.peers.len == 0
    let lateStream = TestBufferStream.new(noop)
    await flood.handleConn(lateStream, FloodSubCodec)
    check:
      lateStream.closed
      flood.peers.len == 0
    await flood.start()
    let nextPeer = PubSubPeer.new(
      randomPeerId(), getStream, nil, FloodSubCodec, 1024, voidPeerHandler
    )
    flood.peers[nextPeer.peerId] = nextPeer
    cancelled = false
    flood.subscribePeer(nextPeer.peerId)
    await flood.stop()
    check cancelled
    await peer.stop()
    await sw.stop()

  asyncTest "closing a send stream during switch shutdown does not redial":
    let
      sw = makeStandardSwitch()
      gossip = GossipSub.init(sw, rng = rng())
      stream = TestBufferStream.new(noop)
    var attempts = 0

    proc getStream(): Future[Stream] {.
        async: (raises: [CancelledError, GetStreamDialError])
    .} =
      inc attempts
      if attempts > 1:
        raise newException(GetStreamDialError, "unexpected reconnect")
      return stream

    let peer = PubSubPeer.new(
      randomPeerId(), getStream, nil, GossipSubCodec_12, 1024, voidPeerHandler
    )
    gossip.peers[peer.peerId] = peer
    sw.mount(gossip)
    await sw.start()
    peer.connect()
    checkUntilTimeout:
      peer.connected

    let stopped = sw.stop()
    await stream.close()
    await stopped
    check attempts == 1
    await peer.stop()

  asyncTest "peer stop waits for connector cancellation cleanup":
    let
      never = newAsyncEvent()
      cleaningUp = newAsyncEvent()
      releaseCleanup = newAsyncEvent()
    var cleanupFinished = false

    proc getStream(): Future[Stream] {.
        async: (raises: [CancelledError, GetStreamDialError])
    .} =
      try:
        await never.wait()
      finally:
        cleaningUp.fire()
        await noCancel releaseCleanup.wait()
        cleanupFinished = true

    let peer = PubSubPeer.new(
      randomPeerId(), getStream, nil, GossipSubCodec_12, 1024, voidPeerHandler
    )
    peer.connect()
    let stopped = peer.stop()
    await cleaningUp.wait()
    check not stopped.finished
    releaseCleanup.fire()
    await stopped
    check cleanupFinished
