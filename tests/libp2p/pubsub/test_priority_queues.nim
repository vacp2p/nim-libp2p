# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/protocols/pubsub/pubsubpeer
import ../../../libp2p/protocols/pubsub/gossipsub/types
import ../../../libp2p/peerid
import ../../../libp2p/crypto/crypto
import ../../tools/unittest

proc randomPeerId(): PeerId =
  let rng = newRng()
  PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()

proc dummyGetConn(): Future[Connection] {.
    async: (raises: [CancelledError, GetConnDialError])
.} =
  raise newException(GetConnDialError, "this is not a real connection")

type PendingConnection = ref object of Connection
  # These futures never finish, they're used to grow the high priority queue
  pendingWrites: seq[Future[void].Raising([CancelledError, LPStreamError])]

type RecorderConnection = ref object of Connection
  # First write blocks, later writes complete and are recorded in order.
  writes: seq[seq[byte]]
  firstWriteFut: Future[void].Raising([CancelledError, LPStreamError])

method initStream*(s: PendingConnection) {.raises: [].} =
  s.objName = "PendingConnection"
  procCall Connection(s).initStream()

method writeLp*(
    s: PendingConnection, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = Future[void].Raising([CancelledError, LPStreamError]).init("PendingConnection.writeLp")
  s.pendingWrites.add(fut)
  fut

method getWrapped*(s: PendingConnection): Connection =
  s

method closeImpl*(s: PendingConnection) {.async: (raises: []).} =
  for fut in s.pendingWrites:
    if not fut.finished:
      fut.fail(newLPStreamClosedError())
  await procCall Connection(s).closeImpl()

proc createPendingConnection(): PendingConnection {.raises: [].} =
  let conn = PendingConnection(dir: Direction.Out, timeout: 0.milliseconds)
  conn.initStream()
  conn

method initStream*(s: RecorderConnection) {.raises: [].} =
  s.objName = "RecorderConnection"
  procCall Connection(s).initStream()

method writeLp*(
    s: RecorderConnection, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writes.add(@msg)
  if s.firstWriteFut.isNil:
    s.firstWriteFut = Future[void].Raising([CancelledError, LPStreamError]).init("RecorderConnection.writeLp")
    s.firstWriteFut
  else:
    let fut = Future[void].Raising([CancelledError, LPStreamError]).init("RecorderConnection.writeLp.completed")
    fut.complete()
    fut

method getWrapped*(s: RecorderConnection): Connection =
  s

method closeImpl*(s: RecorderConnection) {.async: (raises: []).} =
  if not s.firstWriteFut.isNil and not s.firstWriteFut.finished:
    s.firstWriteFut.complete()
  await procCall Connection(s).closeImpl()

proc createRecorderConnection(): RecorderConnection {.raises: [].} =
  let conn = RecorderConnection(dir: Direction.Out, timeout: 0.milliseconds)
  conn.initStream()
  conn

proc releaseFirstWrite(conn: RecorderConnection) {.raises: [].} =
  if not conn.firstWriteFut.isNil and not conn.firstWriteFut.finished:
    conn.firstWriteFut.complete()

proc newDisconnectRecorder(disconnectRequested: ref bool): OnEvent =
  proc recordDisconnect(
      peer: PubSubPeer, event: PubSubPeerEvent
  ) {.gcsafe, raises: [].} =
    if event.kind == PubSubPeerEventKind.DisconnectionRequested:
      disconnectRequested[] = true

  recordDisconnect

proc createTestPeer(
    maxHigh: int = 2,
    maxMedium: int = 2,
    maxLow: int = 2,
    onEvent: OnEvent = nil,
): PubSubPeer =
  PubSubPeer.new(
    randomPeerId(),
    dummyGetConn,
    onEvent,
    GossipSubCodec_12,
    maxMessageSize = 100,
    maxHighPriorityQueueLen = maxHigh,
    maxMediumPriorityQueueLen = maxMedium,
    maxLowPriorityQueueLen = maxLow,
  )

suite "Priority queue behavior":
  teardown:
    checkTrackers()

  asyncTest "Exceeding max high priority messages triggers disconnection event":
    let disconnectRequestedForTest = new bool

    let peer =
      createTestPeer(
        maxHigh = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
      )
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = createPendingConnection()

    # These writes stay pending, so the high-priority queue can actually fill.
    let f1 = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)
    let f2 = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)
    let overflowFut = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)

    check:
      not f1.finished
      not f2.finished

    await overflowFut
    check:
      disconnectRequestedForTest[]
      not peer.hasSendConn()

  asyncTest "Exceeding max medium priority messages drops messages without disconnect":
    let disconnectRequestedForTest = new bool

    let peer =
      createTestPeer(
        maxMedium = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
      )
    let conn = createRecorderConnection()
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = conn

    let highMsg = @[1'u8, 2, 3]
    let mediumMsgs =
      @[
        @[10'u8, 0, 0],
        @[11'u8, 0, 0],
        @[12'u8, 0, 0],
        @[13'u8, 0, 0],
      ]

    # Enqueue a pending high-priority message to disable the fast path
    discard peer.sendEncoded(highMsg, MessagePriority.High)

    for msg in mediumMsgs:
      let f = peer.sendEncoded(msg, MessagePriority.Medium)
      check f.finished

    check conn.writes == @[highMsg]

    # Releasing the first message so medium messages can be sent
    conn.releaseFirstWrite()

    checkUntilTimeout:
      conn.writes.len == 3

    await sleepAsync(10.milliseconds)

    check:
      conn.writes == @[highMsg, mediumMsgs[0], mediumMsgs[1]]
      not disconnectRequestedForTest[]
      peer.hasSendConn()

  asyncTest "Exceeding max low priority messages drops messages without disconnect":
    let disconnectRequestedForTest = new bool

    let peer =
      createTestPeer(
        maxLow = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
      )
    let conn = createRecorderConnection()
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = conn

    let highMsg = @[1'u8, 2, 3]
    let lowMsgs =
      @[
        @[20'u8, 0, 0],
        @[21'u8, 0, 0],
        @[22'u8, 0, 0],
        @[23'u8, 0, 0],
      ]

    # Enqueue a pending high-priority message to disable the fast path
    discard peer.sendEncoded(highMsg, MessagePriority.High)

    for msg in lowMsgs:
      let f = peer.sendEncoded(msg, MessagePriority.Low)
      check f.finished

    check conn.writes == @[highMsg]

    # Releasing the first message so other low messages can be sent
    conn.releaseFirstWrite()

    checkUntilTimeout:
      conn.writes.len == 3

    await sleepAsync(10.milliseconds)

    check:
       conn.writes == @[highMsg, lowMsgs[0], lowMsgs[1]]
       not disconnectRequestedForTest[]
       peer.hasSendConn()

  asyncTest "Empty queues fast-path the first medium or low message":
    let mediumPeer = createTestPeer()
    let lowPeer = createTestPeer()
    defer:
      mediumPeer.stopSendNonHighPriorityTask()
      lowPeer.stopSendNonHighPriorityTask()

    # This is require so it  we can test the send path
    mediumPeer.sendConn = createPendingConnection()
    lowPeer.sendConn = createPendingConnection()

    let mediumFut = mediumPeer.sendEncoded(@[1'u8, 2, 3], MessagePriority.Medium)
    let lowFut = lowPeer.sendEncoded(@[4'u8, 5, 6], MessagePriority.Low)

    check:
      not mediumFut.finished
      not lowFut.finished
      mediumPeer.hasSendConn()
      lowPeer.hasSendConn()
