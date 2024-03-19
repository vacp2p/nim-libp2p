# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[sequtils, strutils, tables, hashes, options, sets, deques]
import stew/results
import chronos, chronicles, nimcrypto/sha2, metrics
import chronos/ratelimit
import rpc/[messages, message, protobuf],
       ../../peerid,
       ../../peerinfo,
       ../../stream/connection,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf,
       ../../utility

export peerid, connection, deques

logScope:
  topics = "libp2p pubsubpeer"

when defined(libp2p_expensive_metrics):
  declareCounter(libp2p_pubsub_sent_messages, "number of messages sent", labels = ["id", "topic"])
  declareCounter(libp2p_pubsub_skipped_received_messages, "number of received skipped messages", labels = ["id"])
  declareCounter(libp2p_pubsub_skipped_sent_messages, "number of sent skipped messages", labels = ["id"])

when defined(pubsubpeer_queue_metrics):
  declareGauge(libp2p_gossipsub_priority_queue_size, "the number of messages in the priority queue", labels = ["id"])
  declareGauge(libp2p_gossipsub_non_priority_queue_size, "the number of messages in the non-priority queue", labels = ["id"])

type
  PeerRateLimitError* = object of CatchableError

  PubSubObserver* = ref object
    onRecv*: proc(peer: PubSubPeer; msgs: var RPCMsg) {.gcsafe, raises: [].}
    onSend*: proc(peer: PubSubPeer; msgs: var RPCMsg) {.gcsafe, raises: [].}

  PubSubPeerEventKind* {.pure.} = enum
    Connected
    Disconnected

  PubSubPeerEvent* = object
    kind*: PubSubPeerEventKind

  GetConn* = proc(): Future[Connection] {.gcsafe, raises: [].}
  DropConn* = proc(peer: PubSubPeer) {.gcsafe, raises: [].} # have to pass peer as it's unknown during init
  OnEvent* = proc(peer: PubSubPeer, event: PubSubPeerEvent) {.gcsafe, raises: [].}

  RpcMessageQueue* = ref object
    # Tracks async tasks for sending high-priority peer-published messages.
    sendPriorityQueue: Deque[Future[void]]
    # Queue for lower-priority messages, like "IWANT" replies and relay messages.
    nonPriorityQueue: AsyncQueue[seq[byte]]
    # Task for processing non-priority message queue.
    sendNonPriorityTask: Future[void]

  PubSubPeer* = ref object of RootObj
    getConn*: GetConn                   # callback to establish a new send connection
    onEvent*: OnEvent                   # Connectivity updates for peer
    codec*: string                      # the protocol that this peer joined from
    sendConn*: Connection               # cached send connection
    connectedFut: Future[void]
    address*: Option[MultiAddress]
    peerId*: PeerId
    handler*: RPCHandler
    observers*: ref seq[PubSubObserver] # ref as in smart_ptr

    score*: float64
    sentIHaves*: Deque[HashSet[MessageId]]
    heDontWants*: Deque[HashSet[MessageId]]
    iHaveBudget*: int
    pingBudget*: int
    maxMessageSize: int
    appScore*: float64 # application specific score
    behaviourPenalty*: float64 # the eventual penalty score
    overheadRateLimitOpt*: Opt[TokenBucket]

    rpcmessagequeue: RpcMessageQueue

  RPCHandler* = proc(peer: PubSubPeer, data: seq[byte]): Future[void]
    {.gcsafe, raises: [].}

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
      if peer.shortAgent.len > 0:
        peer.shortAgent
      else:
        "unknown"
    else:
      "unknown"

func hash*(p: PubSubPeer): Hash =
  p.peerId.hash

func `==`*(a, b: PubSubPeer): bool =
  a.peerId == b.peerId

func shortLog*(p: PubSubPeer): string =
  if p.isNil: "PubSubPeer(nil)"
  else: shortLog(p.peerId)
chronicles.formatIt(PubSubPeer): shortLog(it)

proc connected*(p: PubSubPeer): bool =
  not p.sendConn.isNil and not
    (p.sendConn.closed or p.sendConn.atEof)

proc hasObservers*(p: PubSubPeer): bool =
  p.observers != nil and anyIt(p.observers[], it != nil)

func outbound*(p: PubSubPeer): bool =
  # gossipsub 1.1 spec requires us to know if the transport is outgoing
  # in order to give priotity to connections we make
  # https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#outbound-mesh-quotas
  # This behaviour is presrcibed to counter sybil attacks and ensures that a coordinated inbound attack can never fully take over the mesh
  if not p.sendConn.isNil and p.sendConn.transportDir == Direction.Out:
    true
  else:
    false

proc recvObservers*(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not(isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not(isNil(obs)): # TODO: should never be nil, but...
        obs.onRecv(p, msg)

proc sendObservers(p: PubSubPeer, msg: var RPCMsg) =
  # trigger hooks
  if not(isNil(p.observers)) and p.observers[].len > 0:
    for obs in p.observers[]:
      if not(isNil(obs)): # TODO: should never be nil, but...
        obs.onSend(p, msg)

proc handle*(p: PubSubPeer, conn: Connection) {.async.} =
  debug "starting pubsub read loop",
    conn, peer = p, closed = conn.closed
  try:
    try:
      while not conn.atEof:
        trace "waiting for data", conn, peer = p, closed = conn.closed

        var data = await conn.readLp(p.maxMessageSize)
        trace "read data from peer",
          conn, peer = p, closed = conn.closed,
          data = data.shortLog

        await p.handler(p, data)
        data = newSeq[byte]() # Release memory
    except PeerRateLimitError as exc:
      debug "Peer rate limit exceeded, exiting read while", conn, peer = p, error = exc.msg
    except CatchableError as exc:
      debug "Exception occurred in PubSubPeer.handle",
        conn, peer = p, closed = conn.closed, exc = exc.msg
    finally:
      await conn.close()
  except CancelledError:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError.
    trace "Unexpected cancellation in PubSubPeer.handle"
  except CatchableError as exc:
    trace "Exception occurred in PubSubPeer.handle",
      conn, peer = p, closed = conn.closed, exc = exc.msg
  finally:
    debug "exiting pubsub read loop",
      conn, peer = p, closed = conn.closed

proc connectOnce(p: PubSubPeer): Future[void] {.async.} =
  try:
    if p.connectedFut.finished:
      p.connectedFut = newFuture[void]()
    let newConn = await p.getConn().wait(5.seconds)
    if newConn.isNil:
      raise (ref LPError)(msg: "Cannot establish send connection")

    # When the send channel goes up, subscriptions need to be sent to the
    # remote peer - if we had multiple channels up and one goes down, all
    # stop working so we make an effort to only keep a single channel alive

    trace "Get new send connection", p, newConn

    # Careful to race conditions here.
    # Topic subscription relies on either connectedFut
    # to be completed, or onEvent to be called later
    p.connectedFut.complete()
    p.sendConn = newConn
    p.address = if p.sendConn.observedAddr.isSome: some(p.sendConn.observedAddr.get) else: none(MultiAddress)

    if p.onEvent != nil:
      p.onEvent(p, PubSubPeerEvent(kind: PubSubPeerEventKind.Connected))

    await handle(p, newConn)
  finally:
    if p.sendConn != nil:
      trace "Removing send connection", p, conn = p.sendConn
      await p.sendConn.close()
      p.sendConn = nil

    if not p.connectedFut.finished:
      p.connectedFut.complete()

    try:
      if p.onEvent != nil:
        p.onEvent(p, PubSubPeerEvent(kind: PubSubPeerEventKind.Disconnected))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Errors during diconnection events", error = exc.msg

    # don't cleanup p.address else we leak some gossip stat table

proc connectImpl(p: PubSubPeer) {.async.} =
  try:
    # Keep trying to establish a connection while it's possible to do so - the
    # send connection might get disconnected due to a timeout or an unrelated
    # issue so we try to get a new on
    while true:
      await connectOnce(p)
  except CatchableError as exc: # never cancelled
    debug "Could not establish send connection", msg = exc.msg

proc connect*(p: PubSubPeer) =
  if p.connected:
    return

  asyncSpawn connectImpl(p)

proc hasSendConn*(p: PubSubPeer): bool =
  p.sendConn != nil

template sendMetrics(msg: RPCMsg): untyped =
  when defined(libp2p_expensive_metrics):
    for x in msg.messages:
      for t in x.topicIds:
        # metrics
        libp2p_pubsub_sent_messages.inc(labelValues = [$p.peerId, t])

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
    libp2p_gossipsub_priority_queue_size.set(
      value = p.rpcmessagequeue.sendPriorityQueue.len.int64,
      labelValues = [$p.peerId])

proc sendMsgContinue(conn: Connection, msgFut: Future[void]) {.async.} =
  # Continuation for a pending `sendMsg` future from below
  try:
    await msgFut
    trace "sent pubsub message to remote", conn
  except CatchableError as exc: # never cancelled
    # Because we detach the send call from the currently executing task using
    # asyncSpawn, no exceptions may leak out of it
    trace "Unable to send to remote", conn, msg = exc.msg
    # Next time sendConn is used, it will be have its close flag set and thus
    # will be recycled

    await conn.close() # This will clean up the send connection

proc sendMsgSlow(p: PubSubPeer, msg: seq[byte]) {.async.} =
  # Slow path of `sendMsg` where msg is held in memory while send connection is
  # being set up
  if p.sendConn == nil:
    # Wait for a send conn to be setup. `connectOnce` will
    # complete this even if the sendConn setup failed
    try:
      await p.connectedFut
    except CatchableError as exc:
      debug "Error when waiting for a send conn to be setup", msg = exc.msg, p

  var conn = p.sendConn
  if conn == nil or conn.closed():
    debug "No send connection", msg = shortLog(msg), p
    return

  trace "sending encoded msg to peer", conn, encoded = shortLog(msg), p
  await sendMsgContinue(conn, conn.writeLp(msg))

proc sendMsg(p: PubSubPeer, msg: seq[byte]): Future[void] =
  if p.sendConn != nil and not p.sendConn.closed():
    # Fast path that avoids copying msg (which happens for {.async.})
    let conn = p.sendConn

    trace "sending encoded msg to peer", conn, encoded = shortLog(msg), p
    let f = conn.writeLp(msg)
    if not f.completed():
      sendMsgContinue(conn, f)
    else:
      f
  else:
    sendMsgSlow(p, msg)

proc sendEncoded*(p: PubSubPeer, msg: seq[byte], isHighPriority: bool): Future[void] =
  ## Asynchronously sends an encoded message to a specified `PubSubPeer`.
  ##
  ## Parameters:
  ## - `p`: The `PubSubPeer` instance to which the message is to be sent.
  ## - `msg`: The message to be sent, encoded as a sequence of bytes (`seq[byte]`).
  ## - `isHighPriority`: A boolean indicating whether the message should be treated as high priority.
  ## High priority messages are sent immediately, while low priority messages are queued and sent only after all high
  ## priority messages have been sent.
  doAssert(not isNil(p), "pubsubpeer nil!")

  if msg.len <= 0:
    debug "empty message, skipping", p, msg = shortLog(msg)
    Future[void].completed()
  elif msg.len > p.maxMessageSize:
    info "trying to send a msg too big for pubsub", maxSize=p.maxMessageSize, msgSize=msg.len
    Future[void].completed()
  elif isHighPriority:
    p.clearSendPriorityQueue()
    let f = p.sendMsg(msg)
    if not f.finished:
      p.rpcmessagequeue.sendPriorityQueue.addLast(f)
      when defined(pubsubpeer_queue_metrics):
        libp2p_gossipsub_priority_queue_size.inc(labelValues = [$p.peerId])
    f
  else:
    let f = p.rpcmessagequeue.nonPriorityQueue.addLast(msg)
    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_non_priority_queue_size.inc(labelValues = [$p.peerId])
    f

iterator splitRPCMsg(peer: PubSubPeer, rpcMsg: RPCMsg, maxSize: int, anonymize: bool): seq[byte] =
  ## This iterator takes an `RPCMsg` and sequentially repackages its Messages into new `RPCMsg` instances.
  ## Each new `RPCMsg` accumulates Messages until reaching the specified `maxSize`. If a single Message
  ## exceeds the `maxSize` when trying to fit into an empty `RPCMsg`, the latter is skipped as too large to send.
  ## Every constructed `RPCMsg` is then encoded, optionally anonymized, and yielded as a sequence of bytes.

  var currentRPCMsg = rpcMsg
  currentRPCMsg.messages = newSeq[Message]()

  var currentSize = byteSize(currentRPCMsg)

  for msg in rpcMsg.messages:
    let msgSize = byteSize(msg)

    # Check if adding the next message will exceed maxSize
    if float(currentSize + msgSize) * 1.1 > float(maxSize): # Guessing 10% protobuf overhead
      if currentRPCMsg.messages.len == 0:
        trace "message too big to sent", peer, rpcMsg = shortLog(currentRPCMsg)
        continue # Skip this message

      trace "sending msg to peer", peer, rpcMsg = shortLog(currentRPCMsg)
      yield encodeRpcMsg(currentRPCMsg, anonymize)
      currentRPCMsg = RPCMsg()
      currentSize = 0

    currentRPCMsg.messages.add(msg)
    currentSize += msgSize

  # Check if there is a non-empty currentRPCMsg left to be added
  if currentSize > 0 and currentRPCMsg.messages.len > 0:
    trace "sending msg to peer", peer, rpcMsg = shortLog(currentRPCMsg)
    yield encodeRpcMsg(currentRPCMsg, anonymize)
  else:
    trace "message too big to sent", peer, rpcMsg = shortLog(currentRPCMsg)

proc send*(p: PubSubPeer, msg: RPCMsg, anonymize: bool, isHighPriority: bool) {.raises: [].} =
  ## Asynchronously sends an `RPCMsg` to a specified `PubSubPeer` with an option for anonymization.
  ##
  ## Parameters:
  ## - `p`: The `PubSubPeer` instance to which the message is to be sent.
  ## - `msg`: The `RPCMsg` instance representing the message to be sent.
  ## - `anonymize`: A boolean flag indicating whether the message should be sent with anonymization.
  ## - `isHighPriority`: A boolean flag indicating whether the message should be treated as high priority.
  ## High priority messages are sent immediately, while low priority messages are queued and sent only after all high
  ## priority messages have been sent.
  # When sending messages, we take care to re-encode them with the right
  # anonymization flag to ensure that we're not penalized for sending invalid
  # or malicious data on the wire - in particular, re-encoding protects against
  # some forms of valid but redundantly encoded protobufs with unknown or
  # duplicated fields
  let encoded = if p.hasObservers():
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

  if encoded.len > p.maxMessageSize and msg.messages.len > 1:
    for encodedSplitMsg in splitRPCMsg(p, msg, p.maxMessageSize, anonymize):
      asyncSpawn p.sendEncoded(encodedSplitMsg, isHighPriority)
  else:
    # If the message size is within limits, send it as is
    trace "sending msg to peer", peer = p, rpcMsg = shortLog(msg)
    asyncSpawn p.sendEncoded(encoded, isHighPriority)

proc canAskIWant*(p: PubSubPeer, msgId: MessageId): bool =
  for sentIHave in p.sentIHaves.mitems():
    if msgId in sentIHave:
      sentIHave.excl(msgId)
      return true
  return false

proc sendNonPriorityTask(p: PubSubPeer) {.async.} =
  while true:
     # we send non-priority messages only if there are no pending priority messages
     let msg = await p.rpcmessagequeue.nonPriorityQueue.popFirst()
     while p.rpcmessagequeue.sendPriorityQueue.len > 0:
       p.clearSendPriorityQueue()
       # waiting for the last future minimizes the number of times we have to
       # wait for something (each wait = performance cost) -
       # clearSendPriorityQueue ensures we're not waiting for an already-finished
       # future
       if p.rpcmessagequeue.sendPriorityQueue.len > 0:
        await p.rpcmessagequeue.sendPriorityQueue[^1]
     when defined(pubsubpeer_queue_metrics):
       libp2p_gossipsub_non_priority_queue_size.dec(labelValues = [$p.peerId])
     await p.sendMsg(msg)

proc startSendNonPriorityTask(p: PubSubPeer) =
  debug "starting sendNonPriorityTask", p
  if p.rpcmessagequeue.sendNonPriorityTask.isNil:
    p.rpcmessagequeue.sendNonPriorityTask = p.sendNonPriorityTask()

proc stopSendNonPriorityTask*(p: PubSubPeer) =
  if not p.rpcmessagequeue.sendNonPriorityTask.isNil:
    debug "stopping sendNonPriorityTask", p
    p.rpcmessagequeue.sendNonPriorityTask.cancelSoon()
    p.rpcmessagequeue.sendNonPriorityTask = nil
    p.rpcmessagequeue.sendPriorityQueue.clear()
    p.rpcmessagequeue.nonPriorityQueue.clear()

    when defined(pubsubpeer_queue_metrics):
      libp2p_gossipsub_priority_queue_size.set(labelValues = [$p.peerId], value = 0)
      libp2p_gossipsub_non_priority_queue_size.set(labelValues = [$p.peerId], value = 0)

proc new(T: typedesc[RpcMessageQueue]): T =
  return T(
    sendPriorityQueue: initDeque[Future[void]](),
    nonPriorityQueue: newAsyncQueue[seq[byte]](),
  )

proc new*(
  T: typedesc[PubSubPeer],
  peerId: PeerId,
  getConn: GetConn,
  onEvent: OnEvent,
  codec: string,
  maxMessageSize: int,
  overheadRateLimitOpt: Opt[TokenBucket] = Opt.none(TokenBucket)): T =

  result = T(
    getConn: getConn,
    onEvent: onEvent,
    codec: codec,
    peerId: peerId,
    connectedFut: newFuture[void](),
    maxMessageSize: maxMessageSize,
    overheadRateLimitOpt: overheadRateLimitOpt,
    rpcmessagequeue: RpcMessageQueue.new(),
  )
  result.sentIHaves.addFirst(default(HashSet[MessageId]))
  result.heDontWants.addFirst(default(HashSet[MessageId]))
  result.startSendNonPriorityTask()
