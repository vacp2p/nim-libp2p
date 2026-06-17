# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../../libp2p/protocols/pubsub/[gossipsub, pubsubpeer, peertable]
import ../../../tools/[lifecycle, topology, unittest]
import ../utils

type MockSendStream* = ref object of Connection
  ## Records every write in order. The first `stallCount` writes stay pending.
  ## Later writes complete at once. Closing fails any pending write.
  writes*: seq[seq[byte]] # messages written, in order
  pendingWrites: seq[Future[void].Raising([CancelledError, LPStreamError])]
  stallCount: int

method writeLp*(
    s: MockSendStream, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writes.add(@msg)
  let fut =
    Future[void].Raising([CancelledError, LPStreamError]).init("MockSendStream.writeLp")
  if s.pendingWrites.len >= s.stallCount:
    fut.complete()
  else:
    s.pendingWrites.add(fut)
  fut

method getWrapped*(s: MockSendStream): Connection =
  s

method closeImpl*(s: MockSendStream) {.async: (raises: []).} =
  for fut in s.pendingWrites:
    if not fut.finished:
      fut.fail(newLPStreamClosedError())
  await procCall Connection(s).closeImpl()

proc releasePendingWrites*(s: MockSendStream) {.raises: [].} =
  for fut in s.pendingWrites:
    if not fut.finished:
      fut.complete()

proc stallSendStream*(
    node: GossipSub, topic: string, peerId: PeerId, stallCount: int = int.high
): MockSendStream =
  ## Point `node`'s send stream for `peerId` at a stall stream so its outbound queues fill up.
  ## The replaced stream is left open on purpose: if it closed, the peer would
  ## dial a new stream and overwrite the stall stream. It is closed at teardown.
  let mock =
    MockSendStream(dir: Direction.Out, timeout: 0.milliseconds, stallCount: stallCount)
  mock.initStream()
  node.getPeerByPeerId(topic, peerId).sendStream = mock
  mock

proc message(n: byte): seq[byte] =
  @[n, n, n]

suite "GossipSub Component - Priority Queues":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "High-priority queue overflow disconnects the peer":
    let nodes = generateNodes(2, gossip = true).toGossipSub()
    # Small cap so two pending high messages fill the high-priority queue.
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

    let msg = message(1)
    # Two pending high messages fill the high-priority queue to its cap.
    let f1 = peer.sendEncoded(msg, MessagePriority.High)
    let f2 = peer.sendEncoded(msg, MessagePriority.High)
    check:
      f1.finished
      f2.finished
    # The third high message finds the queue full and disconnects the peer.
    await peer.sendEncoded(msg, MessagePriority.High)

    # Only the first two high messages were written; the third disconnected instead.
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

    # A pending high message keeps the high-priority queue non-empty, so the
    # medium messages are queued rather than sent at once.
    check peer.sendEncoded(message(9), MessagePriority.High).finished

    # maxMedium = 2: the first two are queued, the third overflows and is dropped.
    for i in 0 ..< 3:
      check peer.sendEncoded(message(byte(i)), MessagePriority.Medium).finished

    check:
      # Only the high message was written; the medium messages were queued or dropped.
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

    # A pending high message keeps the high-priority queue non-empty, so the
    # low messages are queued rather than sent at once.
    check peer.sendEncoded(message(9), MessagePriority.High).finished

    # maxLow = 2: the first two are queued, the third overflows and is dropped.
    for i in 0 ..< 3:
      check peer.sendEncoded(message(byte(i)), MessagePriority.Low).finished

    check:
      # Only the high message was written; the low messages were queued or dropped.
      mock.writes.len == 1
      peer.slowPeerPenalty == penaltyBefore + 1.0 # one message dropped
      peer.connected
      nodes[0].switch.isConnected(peerId)
      nodes[0].mesh.hasPeerId(topic, peerId)

  asyncTest "Messages are sent in priority order: high, then medium, then low":
    let nodes = generateNodes(2, gossip = true).toGossipSub()
    # Caps high enough that nothing overflows, only ordering is tested.
    nodes[0].parameters.maxMediumPriorityQueueLen = 4
    nodes[0].parameters.maxLowPriorityQueueLen = 4

    startAndDeferStop(nodes)
    await connectStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    let peerId = nodes[1].peerInfo.peerId
    checkUntilTimeout:
      nodes[0].mesh.hasPeerId(topic, peerId)

    let mock = stallSendStream(nodes[0], topic, peerId, stallCount = 1)
    defer:
      await mock.close()
    let peer = nodes[0].getPeerByPeerId(topic, peerId)

    let highMsgs = @[message(0), message(1)]
    let mediumMsgs = @[message(10), message(11)]
    let lowMsgs = @[message(20), message(21)]

    # A pending high message keeps the high-priority queue non-empty, so the
    # medium and low messages are queued rather than sent at once.
    check peer.sendEncoded(highMsgs[0], MessagePriority.High).finished

    check mock.writes == @[highMsgs[0]]

    # Interleave the sends so the order proves priority precedence, not send order.
    check:
      peer.sendEncoded(mediumMsgs[0], MessagePriority.Medium).finished
      peer.sendEncoded(lowMsgs[0], MessagePriority.Low).finished
      peer.sendEncoded(mediumMsgs[1], MessagePriority.Medium).finished
      peer.sendEncoded(lowMsgs[1], MessagePriority.Low).finished

    # A further high message is written ahead of the queued medium and low messages.
    check peer.sendEncoded(highMsgs[1], MessagePriority.High).finished

    check mock.writes == highMsgs

    # Releasing the high message lets the queues drain: all medium, then all low.
    mock.releasePendingWrites()

    checkUntilTimeout:
      mock.writes == highMsgs & mediumMsgs & lowMsgs
