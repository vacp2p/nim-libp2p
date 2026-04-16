# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/protocols/pubsub/pubsubpeer
import ../../../libp2p/protocols/pubsub/gossipsub/types
import ../../../libp2p/peerid
import ../../tools/unittest

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
  let fut = Future[void].Raising([CancelledError, LPStreamError]).init(
      "PendingConnection.writeLp"
    )
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
    s.firstWriteFut = Future[void].Raising([CancelledError, LPStreamError]).init(
        "RecorderConnection.writeLp"
      )
    s.firstWriteFut
  else:
    let fut = Future[void].Raising([CancelledError, LPStreamError]).init(
        "RecorderConnection.writeLp.completed"
      )
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

proc callbacksDrained(
    fut: FutureBase
): Future[void].Raising([CancelledError]) {.raises: [].} =
  let drained = Future[void].Raising([CancelledError]).init("callbacksDrained")

  proc continuation(udata: pointer) {.gcsafe, raises: [].} =
    let drained = cast[Future[void]](udata)
    if not drained.finished:
      drained.complete()

  fut.addCallback(continuation, cast[pointer](drained))
  drained

proc newDisconnectRecorder(disconnectRequested: ref bool): OnEvent =
  proc recordDisconnect(
      peer: PubSubPeer, event: PubSubPeerEvent
  ) {.gcsafe, raises: [].} =
    if event.kind == PubSubPeerEventKind.DisconnectionRequested:
      disconnectRequested[] = true

  recordDisconnect

proc createTestPeer(
    maxHigh: int = 2, maxMedium: int = 2, maxLow: int = 2, onEvent: OnEvent = nil
): PubSubPeer =
  PubSubPeer.new(
    PeerId.random().expect("random peer id"),
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

  asyncTest "High priority sends return immediately even while writes stay pending":
    let disconnectRequestedForTest = new bool

    let peer = createTestPeer(
      maxHigh = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
    )
    let conn = createPendingConnection()
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = conn

    # These writes stay pending, but sendEncoded itself now completes immediately.
    let f1 = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)
    let f2 = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)
    let f3 = peer.sendEncoded(@[1'u8, 2, 3], MessagePriority.High)

    check:
      f1.finished
      f2.finished
      f3.finished
      conn.pendingWrites.len == 3
      not conn.pendingWrites[0].finished
      not conn.pendingWrites[1].finished
      not conn.pendingWrites[2].finished
      not disconnectRequestedForTest[]
      peer.hasSendConn()

    await conn.close()
    let drain1 = callbacksDrained(conn.pendingWrites[0])
    let drain2 = callbacksDrained(conn.pendingWrites[1])
    let drain3 = callbacksDrained(conn.pendingWrites[2])

    await allFutures(drain1, drain2, drain3)

    check:
      not disconnectRequestedForTest[]

  asyncTest "Medium priority sends fast-path even behind a pending high write":
    let disconnectRequestedForTest = new bool

    let peer = createTestPeer(
      maxMedium = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
    )
    let conn = createRecorderConnection()
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = conn

    let highMsg = @[1'u8, 2, 3]
    let mediumMsgs = @[@[10'u8, 0, 0], @[11'u8, 0, 0], @[12'u8, 0, 0], @[13'u8, 0, 0]]

    # The first high-priority write remains pending on the connection, but later
    # medium-priority sends still take the fast path and complete immediately.
    let highFut = peer.sendEncoded(highMsg, MessagePriority.High)
    check highFut.finished

    for msg in mediumMsgs:
      let f = peer.sendEncoded(msg, MessagePriority.Medium)
      check f.finished

    check conn.writes ==
      @[highMsg, mediumMsgs[0], mediumMsgs[1], mediumMsgs[2], mediumMsgs[3]]

    conn.releaseFirstWrite()

    await callbacksDrained(conn.firstWriteFut)

    check:
      conn.writes ==
        @[highMsg, mediumMsgs[0], mediumMsgs[1], mediumMsgs[2], mediumMsgs[3]]
      not disconnectRequestedForTest[]
      peer.hasSendConn()

  asyncTest "Low priority sends fast-path even behind a pending high write":
    let disconnectRequestedForTest = new bool

    let peer = createTestPeer(
      maxLow = 2, onEvent = newDisconnectRecorder(disconnectRequestedForTest)
    )
    let conn = createRecorderConnection()
    defer:
      peer.stopSendNonHighPriorityTask()

    peer.sendConn = conn

    let highMsg = @[1'u8, 2, 3]
    let lowMsgs = @[@[20'u8, 0, 0], @[21'u8, 0, 0], @[22'u8, 0, 0], @[23'u8, 0, 0]]

    # The first high-priority write remains pending on the connection, but later
    # low-priority sends still take the fast path and complete immediately.
    let highFut = peer.sendEncoded(highMsg, MessagePriority.High)
    check highFut.finished

    for msg in lowMsgs:
      let f = peer.sendEncoded(msg, MessagePriority.Low)
      check f.finished

    check conn.writes == @[highMsg, lowMsgs[0], lowMsgs[1], lowMsgs[2], lowMsgs[3]]

    conn.releaseFirstWrite()

    await callbacksDrained(conn.firstWriteFut)

    check:
      conn.writes == @[highMsg, lowMsgs[0], lowMsgs[1], lowMsgs[2], lowMsgs[3]]
      not disconnectRequestedForTest[]
      peer.hasSendConn()

  asyncTest "Empty queues fast-path medium and low sends while returning completed futures":
    let mediumPeer = createTestPeer()
    let lowPeer = createTestPeer()
    let mediumConn = createPendingConnection()
    let lowConn = createPendingConnection()
    defer:
      mediumPeer.stopSendNonHighPriorityTask()
      lowPeer.stopSendNonHighPriorityTask()

    # This is required so we can test the send path
    mediumPeer.sendConn = mediumConn
    lowPeer.sendConn = lowConn

    let mediumFut = mediumPeer.sendEncoded(@[1'u8, 2, 3], MessagePriority.Medium)
    let lowFut = lowPeer.sendEncoded(@[4'u8, 5, 6], MessagePriority.Low)

    check:
      mediumFut.finished
      lowFut.finished
      mediumConn.pendingWrites.len == 1
      lowConn.pendingWrites.len == 1
      mediumPeer.hasSendConn()
      lowPeer.hasSendConn()

    await mediumConn.close()
    await lowConn.close()
    let mediumDrain = callbacksDrained(mediumConn.pendingWrites[0])
    let lowDrain = callbacksDrained(lowConn.pendingWrites[0])

    checkUntilTimeout:
      mediumDrain.finished
      lowDrain.finished

  test "Queue admission drops medium when backlog exists and medium queue is full":
    let queueAction = determineQueueAction(
      priority = MessagePriority.Medium,
      sendPriorityQueueLen = 1,
      mediumPriorityQueueLen = 1,
      lowPriorityQueueLen = 0,
      maxHighPriorityQueueLen = 2,
      maxMediumPriorityQueueLen = 1,
      maxLowPriorityQueueLen = 2,
    )

    check:
      queueAction.priority == MessagePriority.Medium
      queueAction.send == false
      queueAction.slowPeerPenaltyDelta == 1.0

  test "Queue admission drops low when backlog exists and low queue is full":
    let queueAction = determineQueueAction(
      priority = MessagePriority.Low,
      sendPriorityQueueLen = 1,
      mediumPriorityQueueLen = 0,
      lowPriorityQueueLen = 1,
      maxHighPriorityQueueLen = 2,
      maxMediumPriorityQueueLen = 2,
      maxLowPriorityQueueLen = 1,
    )

    check:
      queueAction.priority == MessagePriority.Low
      queueAction.send == false
      queueAction.slowPeerPenaltyDelta == 1.0

  test "Queue admission disconnects when high priority queue is full":
    let queueAction = determineQueueAction(
      priority = MessagePriority.High,
      sendPriorityQueueLen = 1,
      mediumPriorityQueueLen = 0,
      lowPriorityQueueLen = 0,
      maxHighPriorityQueueLen = 1,
      maxMediumPriorityQueueLen = 2,
      maxLowPriorityQueueLen = 2,
    )

    check:
      queueAction.priority == MessagePriority.High
      queueAction.send == false
      queueAction.slowPeerPenaltyDelta == 0.0
