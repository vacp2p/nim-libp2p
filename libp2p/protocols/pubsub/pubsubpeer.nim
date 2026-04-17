# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import std/[sequtils, tables, hashes, sets, deques]
import results
import chronos, chronicles, nimcrypto/sha2, metrics
import chronos/ratelimit
import
  rpc/[messages, message, protobuf],
  ../../peerid,
  ../../peerinfo,
  ../../stream/connection,
  ../../crypto/crypto,
  ../../protobuf/minprotobuf,
  ../../utility,
  ../../utils/[future, sequninit]

export peerid, connection, deques

logScope:
  topics = "libp2p pubsubpeer"

when defined(libp2p_expensive_metrics):
  declareCounter(
    libp2p_pubsub_sent_messages, "number of messages sent", labels = ["id", "topic"]
  )
  declareCounter(
    libp2p_pubsub_skipped_received_messages,
    "number of received skipped messages",
    labels = ["id"],
  )
  declareCounter(
    libp2p_pubsub_skipped_sent_messages,
    "number of sent skipped messages",
    labels = ["id"],
  )

when defined(pubsubpeer_queue_metrics):
  declareGauge(
    libp2p_gossipsub_high_priority_queue_size,
    "the number of in-flight high-priority sends",
    labels = ["id"],
  )
  declareGauge(
    libp2p_gossipsub_medium_priority_queue_size,
    "the number of messages in the medium-priority queue",
    labels = ["id"],
  )
  declareGauge(
    libp2p_gossipsub_low_priority_queue_size,
    "the number of messages in the low-priority queue",
    labels = ["id"],
  )

  declareCounter(
    libp2p_pubsub_disconnects_over_high_priority_queue_limit,
    "number of peers disconnected due to high-priority queue overflow",
  )
  declareCounter(
    libp2p_pubsub_medium_priority_queue_drops,
    "number of messages dropped from medium-priority queue due to overflow",
  )
  declareCounter(
    libp2p_pubsub_low_priority_queue_drops,
    "number of messages dropped from low-priority queue due to overflow",
  )

const
  DefaultMaxHighPriorityQueueLen* = 256
  DefaultMaxMediumPriorityQueueLen* = 512
  DefaultMaxLowPriorityQueueLen* = 1024

type
  PeerRateLimitError* = object of CatchableError

  GetConnDialError* = object of CatchableError

  PubSubObserver* = ref object
    onRecv*: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
    onSend*: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].}
    onValidated*:
      proc(peer: PubSubPeer, msg: Message, msgId: MessageId) {.gcsafe, raises: [].}

  MessagePriority* {.pure.} = enum
    High
      ## Protocol-critical messages: subscriptions, GRAFT, PRUNE, IHAVE,
      ## IDontWant, control responses. Sent immediately. If max is exceeded
      ## we drop the peer.
    Medium
      ## Locally published messages. Sent before low priority traffic.
      ## They are dropped if exceeded max. Peer is not disconnected.
    Low
      ## Relayed messages and IWANT replies
      ## They are dropped if exceeded max. Peer is not disconnected.

  QueueAction* = object
    priority*: MessagePriority
    send*: bool
      # if true msg should be sent respecting priority, if false it means drop/disconnect
    slowPeerPenaltyDelta*: float64

  PubSubPeerEventKind* {.pure.} = enum
    StreamOpened
    StreamClosed
    DisconnectionRequested
      # tells gossipsub that the transport connection to the peer should be closed

  PubSubPeerEvent* = object
    kind*: PubSubPeerEventKind

  GetConn* =
    proc(): Future[Connection] {.async: (raises: [CancelledError, GetConnDialError]).}
  DropConn* = proc(peer: PubSubPeer) {.gcsafe, raises: [].}
    # have to pass peer as it's unknown during init
  OnEvent* = proc(peer: PubSubPeer, event: PubSubPeerEvent) {.gcsafe, raises: [].}

  QueuedMessage = object
    # Messages sent as medium/low priority are queued and sent on a
    # separate routine.
    data: seq[byte]
    useCustomConn: bool

  RpcMessageQueue* = ref object
    # Tracks async tasks for sending high-priority peer-published messages.
    sendPriorityQueue: Deque[Future[void]]
    # Queue for local published messages
    mediumPriorityQueue: Deque[QueuedMessage]
    # Queue for lower-priority messages, like "IWANT" replies and relay messages.
    lowPriorityQueue: Deque[QueuedMessage]
    # Triggered when a message is added to medium or low queue.
    dataAvailableEvent: AsyncEvent
    # Task for processing non-priority message queue.
    sendNonHighPriorityTask: Future[void]

  CustomConnCreationProc* = proc(
    destAddr: Opt[MultiAddress], destPeerId: PeerId, codec: string
  ): Connection {.gcsafe, raises: [].}

  CustomPeerSelectionProc* = proc(
    allPeers: HashSet[PubSubPeer],
    directPeers: HashSet[PubSubPeer],
    meshPeers: HashSet[PubSubPeer],
    fanoutPeers: HashSet[PubSubPeer],
  ): HashSet[PubSubPeer] {.gcsafe, raises: [].}

  CustomConnectionCallbacks* = object
    customConnCreationCB*: CustomConnCreationProc
    customPeerSelectionCB*: CustomPeerSelectionProc

  PubSubPeer* = ref object of RootObj
    getConn*: GetConn # callback to establish a new send connection
    onEvent*: OnEvent # Connectivity updates for peer
    codec*: string # the protocol that this peer joined from
    sendConn*: Connection # cached send connection
    connectedFut: Future[void]
    address*: Opt[MultiAddress]
    peerId*: PeerId
    handler*: RPCHandler
    observers*: ref seq[PubSubObserver] # ref as in smart_ptr
    score*: float64
    sentIHaves*: Deque[HashSet[MessageId]]
    iDontWants*: Deque[HashSet[SaltedId]]
      ## IDONTWANT contains unvalidated message id:s which may be long and/or
      ## expensive to look up, so we apply the same salting to them as during
      ## unvalidated message processing
    iHaveBudget*: int
    maxMessageSize: int
    appScore*: float64 # application specific score
    slowPeerPenalty*: float64 # penalty from repeated medium/low queue overflow drops
    behaviourPenalty*: float64 # the eventual penalty score
    overheadRateLimitOpt*: Opt[TokenBucket]
    rpcmessagequeue: RpcMessageQueue
    maxHighPriorityQueueLen*: int
    maxMediumPriorityQueueLen*: int
    maxLowPriorityQueueLen*: int
    disconnected: bool
    customConnCallbacks*: Opt[CustomConnectionCallbacks]

  RPCHandler* = proc(peer: PubSubPeer, data: sink seq[byte]): Future[void] {.
    async: (raises: [CancelledError])
  .}

when defined(libp2p_agents_metrics):
  func shortAgent*(p: PubSubPeer): string =
    if p.sendConn.isNil or p.sendConn.getWrapped().isNil:
      "unknown"
    else:
      #TODO the sendConn is setup before identify,
      #so we have to read the parents short agent..
      p.sendConn.getWrapped().shortAgent

proc getAgent*(peer: PubSubPeer): string =
  return
    when defined(libp2p_agents_metrics):
      if peer.shortAgent.len > 0: peer.shortAgent else: "unknown"
    else:
      "unknown"

proc `$`*(p: PubSubPeer): string =
  $p.peerId

func hash*(p: PubSubPeer): Hash =
  p.peerId.hash

func `==`*(a, b: PubSubPeer): bool =
  a.peerId == b.peerId

func shortLog*(p: PubSubPeer): string =
  if p.isNil:
    "PubSubPeer(nil)"
  else:
    shortLog(p.peerId)
chronicles.formatIt(PubSubPeer):
  shortLog(it)

proc connected*(p: PubSubPeer): bool =
  not p.sendConn.isNil and not (p.sendConn.closed or p.sendConn.atEof)

proc hasObservers*(p: PubSubPeer): bool =
  p.observers != nil and anyIt(p.observers[], it != nil)

func outbound*(p: PubSubPeer): bool =
  # gossipsub 1.1 spec requires us to know if the transport is outgoing
  # in order to give priotity to connections we make
  # https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#outbound-mesh-quotas
  # This behaviour is presrcibed to counter sybil attacks and ensures that a coordinated inbound attack can never fully take over the mesh
  if not p.sendConn.isNil and p.sendConn.transportDir == Direction.Out: true else: false

func determineQueueAction*(
    priority: MessagePriority,
    sendPriorityQueueLen, mediumPriorityQueueLen, lowPriorityQueueLen: int,
    maxHighPriorityQueueLen, maxMediumPriorityQueueLen, maxLowPriorityQueueLen: int,
): QueueAction =
  let emptyQueues =
    sendPriorityQueueLen == 0 and mediumPriorityQueueLen == 0 and
    lowPriorityQueueLen == 0

  var send = true
  var slowPeerPenaltyDelta = 0.0
  var priority = priority

  if priority == MessagePriority.High or emptyQueues:
    # If queues are empty, we can send medium/low messages immediatly
    # thus setting the priority of the message to high
    priority = MessagePriority.High

    if sendPriorityQueueLen >= maxHighPriorityQueueLen:
      send = false
  elif priority == MessagePriority.Medium:
    if mediumPriorityQueueLen >= maxMediumPriorityQueueLen:
      send = false
      slowPeerPenaltyDelta = 1.0
  else:
    if lowPriorityQueueLen >= maxLowPriorityQueueLen:
      slowPeerPenaltyDelta = 1.0
      send = false

  QueueAction(
    priority: priority, send: send, slowPeerPenaltyDelta: slowPeerPenaltyDelta
  )

func determineQueueAction*(
    priority: MessagePriority,
    rpcmessagequeue: RpcMessageQueue,
    maxHighPriorityQueueLen, maxMediumPriorityQueueLen, maxLowPriorityQueueLen: int,
): QueueAction =
  determineQueueAction(
    priority, rpcmessagequeue.sendPriorityQueue.len,
    rpcmessagequeue.mediumPriorityQueue.len, rpcmessagequeue.lowPriorityQueue.len,
    maxHighPriorityQueueLen, maxMediumPriorityQueueLen, maxLowPriorityQueueLen,
  )

proc recvObservers*(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not (isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not (isNil(obs)): # TODO: should never be nil, but...
        if not (isNil(obs.onRecv)):
          obs.onRecv(p, msg)

proc validatedObservers*(p: PubSubPeer, msg: Message, msgId: MessageId) =
  # trigger hooks
  if not (isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not (isNil(obs.onValidated)):
        obs.onValidated(p, msg, msgId)

proc sendObservers(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not (isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not (isNil(obs)): # TODO: should never be nil, but...
        if not (isNil(obs.onSend)):
          obs.onSend(p, msg)

proc runHandleLoop*(
    p: PubSubPeer, conn: Connection
) {.async: (raises: [CancelledError]).} =
  debug "starting pubsub read loop", conn, peer = p, closed = conn.closed
  defer:
    debug "exiting pubsub read loop", conn, peer = p, closed = conn.closed

  while not conn.atEof:
    trace "waiting for data", conn, peer = p, closed = conn.closed

    let data =
      try:
        await conn.readLp(p.maxMessageSize)
      except LPStreamEOFError:
        return
      except LPStreamError as e:
        debug "Exception occurred reading message PubSubPeer.handle",
          conn, peer = p, closed = conn.closed, description = e.msg
        return

    trace "read data from peer",
      conn, peer = p, closed = conn.closed, data = data.shortLog

    await p.handler(p, data)

proc closeSendConn(
    p: PubSubPeer, event: PubSubPeerEventKind
) {.async: (raises: [CancelledError]).} =
  if p.sendConn != nil:
    trace "Removing send connection", p, conn = p.sendConn
    await p.sendConn.close()
    p.sendConn = nil

  if not p.connectedFut.finished:
    p.connectedFut.complete()

  try:
    if p.onEvent != nil:
      p.onEvent(p, PubSubPeerEvent(kind: event))
  except CancelledError as exc:
    raise exc
  # don't cleanup p.address else we leak some gossip stat table

proc connectOnce(
    p: PubSubPeer
): Future[void] {.async: (raises: [CancelledError, GetConnDialError]).} =
  try:
    if p.connectedFut.finished:
      p.connectedFut = newFuture[void]()
    let newConn =
      try:
        await p.getConn().wait(5.seconds)
      except AsyncTimeoutError:
        raise newException(GetConnDialError, "establishing connection timed out")

    # When the send channel goes up, subscriptions need to be sent to the
    # remote peer - if we had multiple channels up and one goes down, all
    # stop working so we make an effort to only keep a single channel alive

    trace "Get new send connection", p, newConn

    # Careful to race conditions here.
    # Topic subscription relies on either connectedFut
    # to be completed, or onEvent to be called later
    p.sendConn = newConn
    p.address =
      if p.sendConn.observedAddr.isSome:
        Opt.some(p.sendConn.observedAddr.get)
      else:
        Opt.none(MultiAddress)

    if p.codec == "":
      # if codec was not know, it can be retrieved from newly established connection
      p.codec = newConn.protocol

    p.connectedFut.complete()
    if p.onEvent != nil:
      p.onEvent(p, PubSubPeerEvent(kind: PubSubPeerEventKind.StreamOpened))

    await p.runHandleLoop(newConn)
  finally:
    await p.closeSendConn(PubSubPeerEventKind.StreamClosed)

proc connectImpl(p: PubSubPeer) {.async: (raises: []).} =
  try:
    # Keep trying to establish a connection while it's possible to do so - the
    # send connection might get disconnected due to a timeout or an unrelated
    # issue so we try to get a new on
    while true:
      if p.disconnected:
        if not p.connectedFut.finished:
          p.connectedFut.complete()
        return
      await connectOnce(p)
  except CancelledError as exc:
    debug "Could not establish send connection", description = exc.msg
  except GetConnDialError as exc:
    debug "Could not establish send connection", description = exc.msg

proc connect*(p: PubSubPeer) =
  if p.connected:
    return

  asyncSpawn connectImpl(p)

proc hasSendConn*(p: PubSubPeer): bool =
  p.sendConn != nil

template sendMetrics(msg: RPCMsg): untyped =
  when defined(libp2p_expensive_metrics):
    for x in msg.messages:
      # metrics
      libp2p_pubsub_sent_messages.inc(labelValues = [$p.peerId, x.topic])

proc clearSendPriorityQueue(p: PubSubPeer) =
  if p.rpcmessagequeue.sendPriorityQueue.len == 0:
    return # fast path

  while p.rpcmessagequeue.sendPriorityQueue.len > 0 and
      p.rpcmessagequeue.sendPriorityQueue[0].finished:
    discard p.rpcmessagequeue.sendPriorityQueue.popFirst()

  while p.rpcmessagequeue.sendPriorityQueue.len > 0 and
      p.rpcmessagequeue.sendPriorityQueue[^1].finished:
    discard p.rpcmessagequeue.sendPriorityQueue.popLast()

  when defined(pubsubpeer_queue_metrics):
    libp2p_gossipsub_high_priority_queue_size.set(
      value = p.rpcmessagequeue.sendPriorityQueue.len.int64, labelValues = [$p.peerId]
    )

proc sendMsgContinue(conn: Connection, msgFut: Future[void]) {.async: (raises: []).} =
  # Continuation for a pending `sendMsg` future from below
  try:
    await msgFut
    trace "sent pubsub message to remote", conn
  except CatchableError as exc:
    trace "Unexpected exception in sendMsgContinue", conn, description = exc.msg
    # Next time sendConn is used, it will be have its close flag set and thus
    # will be recycled
    await conn.close() # This will clean up the send connection

proc sendMsgSlow(p: PubSubPeer, msg: seq[byte]) {.async: (raises: [CancelledError]).} =
  # Slow path of `sendMsg` where msg is held in memory while send connection is
  # being set up
  if p.sendConn == nil:
    # Wait for a send conn to be setup. `connectOnce` will
    # complete this even if the sendConn setup failed
    discard await race(p.connectedFut)

  var conn = p.sendConn
  if conn == nil or conn.closed():
    debug "No send connection", p, payload = shortLog(msg)
    return

  trace "sending encoded msg to peer", conn, encoded = shortLog(msg)
  await sendMsgContinue(conn, conn.writeLp(msg))

proc sendMsg(
    p: PubSubPeer, msg: seq[byte], useCustomConn: bool = false
): Future[void] {.async: (raises: []).} =
  type ConnectionType = enum
    ctCustom
    ctSend
    ctSlow

  var slowPath = false
  let (conn, connType) =
    if useCustomConn and p.customConnCallbacks.isSome:
      let address = p.address
      (
        p.customConnCallbacks.get().customConnCreationCB(address, p.peerId, p.codec),
        ctCustom,
      )
    elif p.sendConn != nil and not p.sendConn.closed():
      (p.sendConn, ctSend)
    else:
      slowPath = true
      (nil, ctSlow)

  if not slowPath:
    trace "sending encoded msg to peer",
      conntype = $connType, conn = conn, encoded = shortLog(msg)
    let f = conn.writeLp(msg)
    if not f.completed():
      sendMsgContinue(conn, f)
    else:
      if f.failed():
        trace "sending encoded msg to peer failed", description = f.error.msg
      else:
        trace "sent pubsub message to remote", conn
      f
  else:
    trace "sending encoded msg to peer via slow path"
    sendMsgSlow(p, msg)

proc disconnectPeer(p: PubSubPeer): Future[void] =
  if not p.disconnected:
    p.disconnected = true
    when defined(pubsubpeer_queue_metrics):
      libp2p_pubsub_disconnects_over_high_priority_queue_limit.inc()
    return p.closeSendConn(PubSubPeerEventKind.DisconnectionRequested)

  return newFutureCompleted[void]()

proc sendHighPriorityMessage(
    p: PubSubPeer, msg: seq[byte], useCustomConn: bool
): Future[void] =
  let f = p.sendMsg(msg, useCustomConn)
  if not f.finished:
    p.rpcmessagequeue.sendPriorityQueue.addLast(f)
    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_high_priority_queue_size.inc(labelValues = [$p.peerId])
  return f

proc enqueueNonHighPriorityMessage(
    p: PubSubPeer, msg: seq[byte], useCustomConn: bool, priority: MessagePriority
): Future[void] =
  let queuedMsg = QueuedMessage(data: msg, useCustomConn: useCustomConn)
  case priority
  of MessagePriority.Medium:
    p.rpcmessagequeue.mediumPriorityQueue.addLast(queuedMsg)
    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_medium_priority_queue_size.inc(labelValues = [$p.peerId])
  of MessagePriority.Low:
    p.rpcmessagequeue.lowPriorityQueue.addLast(queuedMsg)
    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_low_priority_queue_size.inc(labelValues = [$p.peerId])
  of MessagePriority.High:
    raiseAssert "high-priority messages are not enqueued"
  p.rpcmessagequeue.dataAvailableEvent.fire()

  return newFutureCompleted[void]()

proc dropNonHighPriorityMessage(
    p: PubSubPeer, slowPeerPenaltyDelta: float64, priority: MessagePriority
): Future[void] =
  p.slowPeerPenalty += slowPeerPenaltyDelta
  case priority
  of MessagePriority.Medium:
    when defined(pubsubpeer_queue_metrics):
      libp2p_pubsub_medium_priority_queue_drops.inc()
    trace "medium priority queue full, dropping message", p
  of MessagePriority.Low:
    when defined(pubsubpeer_queue_metrics):
      libp2p_pubsub_low_priority_queue_drops.inc()
    trace "low priority queue full, dropping message", p
  of MessagePriority.High:
    raiseAssert "high-priority messages are not dropped via queue overflow scoring"
  return newFutureCompleted[void]()

proc sendEncoded*(
    p: PubSubPeer,
    msg: seq[byte],
    priority: MessagePriority,
    useCustomConn: bool = false,
): Future[void] =
  ## Asynchronously sends an encoded message to a specified `PubSubPeer` according to its priority.
  ##
  ## Parameters:
  ## - `p`: The `PubSubPeer` instance to which the message is to be sent.
  ## - `msg`: The message to be sent, encoded as a sequence of bytes (`seq[byte]`).
  ## - `priority`: 
  ##   - `High` or any priority when all queues are empty: sent immediately
  ##   - `Medium`: queued in `mediumPriorityQueue`. Dropped when full.
  ##   - `Low`: queued in `lowPriorityQueue`. Dropped when full.
  ## - `useCustomConn`: boolean used to indicate if a custom connection is going to 
  ##   be used for sending this message
  ## Low and medium priority messages are queued and sent only after all high
  ## priority messages have been sent.
  doAssert(not isNil(p), "pubsubpeer nil!")

  p.clearSendPriorityQueue()

  if msg.len <= 0:
    debug "empty message, skipping", p, payload = shortLog(msg)
    newFutureCompleted[void]()
  elif msg.len > p.maxMessageSize:
    info "trying to send a msg too big for pubsub",
      maxSize = p.maxMessageSize, msgSize = msg.len
    newFutureCompleted[void]()
  else:
    let action = determineQueueAction(
      priority, p.rpcmessagequeue, p.maxHighPriorityQueueLen,
      p.maxMediumPriorityQueueLen, p.maxLowPriorityQueueLen,
    )

    case action.priority
    of High:
      if action.send:
        p.sendHighPriorityMessage(msg, useCustomConn)
      else:
        p.disconnectPeer()
    of Medium, Low:
      if action.send:
        p.enqueueNonHighPriorityMessage(msg, useCustomConn, action.priority)
      else:
        p.dropNonHighPriorityMessage(action.slowPeerPenaltyDelta, action.priority)

iterator splitRPCMsg(
    peer: PubSubPeer, rpcMsg: RPCMsg, maxSize: int, anonymize: bool
): seq[byte] =
  ## This iterator takes an `RPCMsg` and sequentially repackages its Messages into new `RPCMsg` instances.
  ## Each new `RPCMsg` accumulates Messages until reaching the specified `maxSize`. If a single Message
  ## exceeds the `maxSize` when trying to fit into an empty `RPCMsg`, the latter is skipped as too large to send.
  ## Every constructed `RPCMsg` is then encoded, optionally anonymized, and yielded as a sequence of bytes.

  var currentRPCMsg = RPCMsg()
  var currentSize = 0

  for msg in rpcMsg.messages:
    let msgSize = byteSize(msg)

    # Check if adding the next message will exceed maxSize
    if currentSize + msgSize > maxSize:
      if msgSize > maxSize:
        warn "message too big to sent", peer, rpcMsg = shortLog(msg)
        continue # Skip this message

      trace "sending msg to peer", peer, rpcMsg = shortLog(currentRPCMsg)
      yield encodeRpcMsg(currentRPCMsg, anonymize)
      currentRPCMsg = RPCMsg()
      currentSize = 0

    currentRPCMsg.messages.add(msg)
    currentSize += msgSize

  # Check if there is a non-empty currentRPCMsg left to be added
  if currentRPCMsg.messages.len > 0:
    trace "sending msg to peer", peer, rpcMsg = shortLog(currentRPCMsg)
    yield encodeRpcMsg(currentRPCMsg, anonymize)

proc send*(
    p: PubSubPeer,
    msg: RPCMsg,
    anonymize: bool,
    priority: MessagePriority,
    useCustomConn: bool = false,
) {.raises: [].} =
  ## Asynchronously sends an `RPCMsg` to a specified `PubSubPeer` with an option for anonymization.
  ##
  ## Parameters:
  ## - `p`: The `PubSubPeer` instance to which the message is to be sent.
  ## - `msg`: The `RPCMsg` instance representing the message to be sent.
  ## - `anonymize`: A boolean flag indicating whether the message should be sent with anonymization.
  ## - `priority`: The message priority level (`High`, `Medium`, or `Low`).
  ##   High priority messages are sent immediately, medium and low priority messages are queued
  ##   and sent only after all high priority messages have been sent.
  # When sending messages, we take care to re-encode them with the right
  # anonymization flag to ensure that we're not penalized for sending invalid
  # or malicious data on the wire - in particular, re-encoding protects against
  # some forms of valid but redundantly encoded protobufs with unknown or
  # duplicated fields
  let encoded =
    if p.hasObservers():
      var mm = msg
      # trigger send hooks
      p.sendObservers(mm)
      sendMetrics(mm)
      encodeRpcMsg(mm, anonymize)
    else:
      # If there are no send hooks, we redundantly re-encode the message to
      # protobuf for every peer - this could easily be improved!
      sendMetrics(msg)
      encodeRpcMsg(msg, anonymize)

  # Messages should not exceed 90% of maxMessageSize. Guessing 10% protobuf overhead.
  let maxEncodedMsgSize = (p.maxMessageSize * 90) div 100

  if encoded.len > maxEncodedMsgSize and msg.messages.len > 1:
    for encodedSplitMsg in splitRPCMsg(p, msg, maxEncodedMsgSize, anonymize):
      asyncSpawn p.sendEncoded(encodedSplitMsg, priority, useCustomConn)
  else:
    # If the message size is within limits, send it as is
    trace "sending msg to peer", peer = p, rpcMsg = shortLog(msg)
    asyncSpawn p.sendEncoded(encoded, priority, useCustomConn)

proc canAskIWant*(p: PubSubPeer, msgId: MessageId): bool =
  for sentIHave in p.sentIHaves.mitems():
    if msgId in sentIHave:
      sentIHave.excl(msgId)
      return true
  return false

proc sendNonHighPriorityTask(p: PubSubPeer) {.async: (raises: [CancelledError]).} =
  while true:
    # we send non-priority messages only if there are no pending priority messages
    while p.rpcmessagequeue.mediumPriorityQueue.len == 0 and
        p.rpcmessagequeue.lowPriorityQueue.len == 0:
      await p.rpcmessagequeue.dataAvailableEvent.wait()
      p.rpcmessagequeue.dataAvailableEvent.clear()

    var priority = MessagePriority.Low
    let msg =
      if p.rpcmessagequeue.mediumPriorityQueue.len != 0:
        priority = MessagePriority.Medium
        p.rpcmessagequeue.mediumPriorityQueue.popFirst()
      elif p.rpcmessagequeue.lowPriorityQueue.len != 0:
        p.rpcmessagequeue.lowPriorityQueue.popFirst()
      else:
        continue

    while p.rpcmessagequeue.sendPriorityQueue.len > 0:
      p.clearSendPriorityQueue()
      # waiting for the last future minimizes the number of times we have to
      # wait for something (each wait = performance cost) -
      # clearSendPriorityQueue ensures we're not waiting for an already-finished
      # future
      if p.rpcmessagequeue.sendPriorityQueue.len > 0:
        # `race` prevents `p.rpcmessagequeue.sendPriorityQueue[^1]` from being
        # cancelled when this task is cancelled
        discard await race(p.rpcmessagequeue.sendPriorityQueue[^1])
    when defined(pubsubpeer_queue_metrics):
      if priority == MessagePriority.Medium:
        libp2p_gossipsub_medium_priority_queue_size.dec(labelValues = [$p.peerId])
      else:
        libp2p_gossipsub_low_priority_queue_size.dec(labelValues = [$p.peerId])

    await p.sendMsg(msg.data, msg.useCustomConn)

proc startSendNonHighPriorityTask(p: PubSubPeer) =
  debug "starting sendNonHighPriorityTask", p
  if p.rpcmessagequeue.sendNonHighPriorityTask.isNil:
    p.rpcmessagequeue.sendNonHighPriorityTask = p.sendNonHighPriorityTask()

proc stopSendNonHighPriorityTask*(p: PubSubPeer) =
  if not p.rpcmessagequeue.sendNonHighPriorityTask.isNil:
    debug "stopping sendNonHighPriorityTask", p
    p.rpcmessagequeue.sendNonHighPriorityTask.cancelSoon()
    p.rpcmessagequeue.sendNonHighPriorityTask = nil
    p.rpcmessagequeue.sendPriorityQueue.clear()
    p.rpcmessagequeue.mediumPriorityQueue.clear()
    p.rpcmessagequeue.lowPriorityQueue.clear()

    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_high_priority_queue_size.set(
        labelValues = [$p.peerId], value = 0
      )
      libp2p_gossipsub_medium_priority_queue_size.set(
        labelValues = [$p.peerId], value = 0
      )
      libp2p_gossipsub_low_priority_queue_size.set(labelValues = [$p.peerId], value = 0)

proc new(T: typedesc[RpcMessageQueue]): T =
  return T(
    sendPriorityQueue: initDeque[Future[void]](),
    mediumPriorityQueue: initDeque[QueuedMessage](),
    lowPriorityQueue: initDeque[QueuedMessage](),
    dataAvailableEvent: newAsyncEvent(),
  )

proc new*(
    T: typedesc[PubSubPeer],
    peerId: PeerId,
    getConn: GetConn,
    onEvent: OnEvent,
    codec: string,
    maxMessageSize: int,
    maxHighPriorityQueueLen: int = DefaultMaxHighPriorityQueueLen,
    maxMediumPriorityQueueLen: int = DefaultMaxMediumPriorityQueueLen,
    maxLowPriorityQueueLen: int = DefaultMaxLowPriorityQueueLen,
    overheadRateLimitOpt: Opt[TokenBucket] = Opt.none(TokenBucket),
    customConnCallbacks: Opt[CustomConnectionCallbacks] =
      Opt.none(CustomConnectionCallbacks),
): T =
  let response = T(
    getConn: getConn,
    onEvent: onEvent,
    codec: codec,
    peerId: peerId,
    connectedFut: newFuture[void](),
    maxMessageSize: maxMessageSize,
    overheadRateLimitOpt: overheadRateLimitOpt,
    rpcmessagequeue: RpcMessageQueue.new(),
    maxHighPriorityQueueLen: maxHighPriorityQueueLen,
    maxMediumPriorityQueueLen: maxMediumPriorityQueueLen,
    maxLowPriorityQueueLen: maxLowPriorityQueueLen,
    customConnCallbacks: customConnCallbacks,
  )
  response.sentIHaves.addFirst(default(HashSet[MessageId]))
  response.iDontWants.addFirst(default(HashSet[SaltedId]))
  response.startSendNonHighPriorityTask()

  response
