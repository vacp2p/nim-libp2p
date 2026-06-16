# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../../libp2p/protocols/pubsub/[gossipsub, pubsubpeer, peertable]
import ../../../tools/[lifecycle, topology, unittest]
import ../utils

type MockSendStream* = ref object of Connection
  ## Send stream whose writes never finish, so a peer's send queues fill up.
  ## Closing it fails the pending writes.
  writes*: seq[seq[byte]] # payloads written, in order
  pendingWrites: seq[Future[void].Raising([CancelledError, LPStreamError])]

method writeLp*(
    s: MockSendStream, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writes.add(@msg)
  let fut =
    Future[void].Raising([CancelledError, LPStreamError]).init("MockSendStream.writeLp")
  s.pendingWrites.add(fut)
  fut

method getWrapped*(s: MockSendStream): Connection =
  s

method closeImpl*(s: MockSendStream) {.async: (raises: []).} =
  for fut in s.pendingWrites:
    if not fut.finished:
      fut.fail(newLPStreamClosedError())
  await procCall Connection(s).closeImpl()

proc stallSendStream*(node: GossipSub, topic: string, peerId: PeerId): MockSendStream =
  ## Point `node`'s send stream for `peerId` at a stall stream so its outbound queues fill up.
  ## The replaced stream is left open on purpose: if it closed, the peer would
  ## dial a new stream and overwrite the stall stream. It is closed at teardown.
  let mock = MockSendStream(dir: Direction.Out, timeout: 0.milliseconds)
  mock.initStream()
  node.getPeerByPeerId(topic, peerId).sendStream = mock
  mock

suite "GossipSub Component - Priority Queues":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "High-priority queue overflow disconnects the peer":
    let nodes = generateNodes(2, gossip = true).toGossipSub()
    # Small cap so two pending sends fill the high-priority queue.
    nodes[0].parameters.maxHighPriorityQueueLen = 2

    startAndDeferStop(nodes)
    await connectStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    let peerId = nodes[1].peerInfo.peerId
    let mock = stallSendStream(nodes[0], topic, peerId)
    defer:
      await mock.close()
    let peer = nodes[0].getPeerByPeerId(topic, peerId)
    let penaltyBefore = peer.slowPeerPenalty

    let msg = @[1'u8, 2, 3]
    # Two pending high sends fill the high-priority queue to its cap.
    let f1 = peer.sendEncoded(msg, MessagePriority.High)
    let f2 = peer.sendEncoded(msg, MessagePriority.High)
    check:
      f1.finished
      f2.finished
    # The third send finds the queue full and asks to disconnect the peer.
    await peer.sendEncoded(msg, MessagePriority.High)

    # Only the first two sends were written; the third disconnected instead.
    check:
      mock.writes.len == 2
      peer.slowPeerPenalty == penaltyBefore
    checkUntilTimeout:
      not nodes[0].switch.isConnected(peerId)
      not nodes[0].gossipsub.hasPeerId(topic, peerId)
      not nodes[0].mesh.hasPeerId(topic, peerId)

  asyncTest "Medium-priority queue overflow drops the message but keeps the peer":
    let nodes = generateNodes(2, gossip = true).toGossipSub()
    nodes[0].parameters.maxMediumPriorityQueueLen = 2

    startAndDeferStop(nodes)
    await connectStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    let peerId = nodes[1].peerInfo.peerId
    checkUntilTimeout:
      nodes[0].mesh.hasPeerId(topic, peerId)

    let mock = stallSendStream(nodes[0], topic, peerId)
    defer:
      await mock.close()
    let peer = nodes[0].getPeerByPeerId(topic, peerId)
    let penaltyBefore = peer.slowPeerPenalty

    # Send one high message. Its write stays pending on the stalled stream and
    # sits in the high-priority queue, so the queue is non-empty and the medium
    # messages are queued instead of sent at once as high. 
    # sendEncoded itself returns an already-completed future.
    check peer.sendEncoded(@[9'u8, 9, 9], MessagePriority.High).finished

    # maxMedium = 2: the first two are queued, the third overflows and is dropped.
    for i in 0 ..< 3:
      check peer.sendEncoded(@[byte(i), 0, 0], MessagePriority.Medium).finished

    check:
      # Only the high send was written, the medium messages stayed queued or dropped.
      mock.writes.len == 1
      peer.slowPeerPenalty == penaltyBefore + 1.0 # one message dropped
      peer.connected
      nodes[0].switch.isConnected(peerId)
      nodes[0].mesh.hasPeerId(topic, peerId)

  asyncTest "Low-priority queue overflow drops the message but keeps the peer":
    let nodes = generateNodes(2, gossip = true).toGossipSub()
    nodes[0].parameters.maxLowPriorityQueueLen = 2

    startAndDeferStop(nodes)
    await connectStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    let peerId = nodes[1].peerInfo.peerId
    checkUntilTimeout:
      nodes[0].mesh.hasPeerId(topic, peerId)

    let mock = stallSendStream(nodes[0], topic, peerId)
    defer:
      await mock.close()
    let peer = nodes[0].getPeerByPeerId(topic, peerId)
    let penaltyBefore = peer.slowPeerPenalty

    # Send one high message. Its write stays pending on the stalled stream and
    # sits in the high-priority queue, so the queue is non-empty and the low
    # messages are queued instead of sent at once as high. 
    # sendEncoded itself returns an already-completed future.
    check peer.sendEncoded(@[9'u8, 9, 9], MessagePriority.High).finished

    # maxLow = 2: the first two are queued, the third overflows and is dropped.
    for i in 0 ..< 3:
      check peer.sendEncoded(@[byte(i), 0, 0], MessagePriority.Low).finished

    check:
      # Only the high send was written, the low messages stayed queued or dropped.
      mock.writes.len == 1
      peer.slowPeerPenalty == penaltyBefore + 1.0 # one message dropped
      peer.connected
      nodes[0].switch.isConnected(peerId)
      nodes[0].mesh.hasPeerId(topic, peerId)
