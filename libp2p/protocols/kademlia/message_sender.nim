# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Per-peer outbound stream reuse for Kademlia RPCs.
##
## One stream is kept open per peer and shared by every RPC to that peer, so a
## lookup pays the stream negotiation cost once instead of once per message.
## RPCs on a peer's stream are serialized by a lock, because the wire format
## carries no request ids to match interleaved replies with.
##
## Mirrors go-libp2p's ``internal/net/message_manager.go``.

import std/tables
import chronos, chronicles, results
import ../../[peerid, switch]
import ../../stream/connection
import ./kademlia_metrics

export results

logScope:
  topics = "kad-dht message-sender"

const DefaultMaxStreamReuseFailures* = 3
  ## Once reuse has broken this many times for a peer, treat it as unable to
  ## serve more than one RPC per stream and give it a fresh stream every time.
  ## Mirrors go-libp2p's ``streamReuseTries``.

type
  SendStage* = enum
    ## How far a send got before it gave up. Callers distinguish these: an RPC
    ## that reached the remote but drew no reply differs from one that never
    ## left the node.
    dialStage
    writeStage
    readStage

  SendError* = object
    stage*: SendStage
    msg*: string

  PeerMessageSender = ref object
    lock: AsyncLock ## serializes the RPCs sharing `stream`
    stream: Stream ## nil while no stream is open
    users: int ## RPCs holding or waiting for `lock`
    reuseFailures: int
    invalidated: bool
      ## Set when the peer disconnects or the sender shuts down, so an RPC that
      ## is mid-flight at that moment does not open a replacement stream.

  MessageSender* = ref object
    switch: Switch
    onDisconnect: ConnEventHandler
    codec: string
    maxMsgSize: int
    maxReuseFailures: int
    senders: Table[PeerId, PeerMessageSender]
    stopped: bool

  PreparedStream = tuple[stream: Stream, reused: bool]

func init(
    T: typedesc[SendError], stage: SendStage, msg: string
): SendError {.raises: [].} =
  SendError(stage: stage, msg: msg)

func `$`*(e: SendError): string {.raises: [].} =
  $e.stage & ": " & e.msg

proc timeLeft(deadline: Moment): Duration {.raises: [].} =
  ## Zero once the deadline passed: chronos clamps a negative `Duration`.
  deadline - Moment.now()

proc discardStream(
    ps: PeerMessageSender, stream: Stream
) {.async: (raises: []), gcsafe.} =
  ## Reset rather than close: closing only half-closes the channel, so an
  ## unread reply stays in the read buffer and blocks the muxer for every other
  ## channel on that connection.
  if ps.stream == stream:
    ps.stream = nil
  await stream.reset()

proc retireStream(
    ps: PeerMessageSender, stream: Stream, deadline: Moment
) {.async: (raises: []), gcsafe.} =
  ## Close rather than reset, so a message written just before still reaches the
  ## remote, then wait for the remote's EOF so nothing stays buffered on the
  ## muxer. A remote that never answers the close gets a reset instead of an
  ## unbounded wait.
  if ps.stream == stream:
    ps.stream = nil
  if not await noCancel stream.closeWithEOF().withTimeout(deadline.timeLeft()):
    await stream.reset()

proc dropPeer*(ms: MessageSender, peerId: PeerId) {.async: (raises: []), gcsafe.} =
  ## Forget a peer's stream. The RPC holding it, if any, fails on its next
  ## read or write and does not reopen.
  let ps = ms.senders.getOrDefault(peerId)
  if ps.isNil():
    return
  ms.senders.del(peerId)
  ps.invalidated = true
  let stream = move ps.stream
  if not stream.isNil():
    await stream.reset()

proc start*(ms: MessageSender) {.raises: [].} =
  ms.stopped = false
  ms.switch.addConnEventHandler(ms.onDisconnect, ConnEventKind.Disconnected)

proc stop*(ms: MessageSender) {.async: (raises: []), gcsafe.} =
  ## Reject further sends, take the disconnect handler back off the switch and
  ## reset every open stream. `start` reopens it.
  ms.stopped = true
  ms.switch.removeConnEventHandler(ms.onDisconnect, ConnEventKind.Disconnected)
  let senders = move ms.senders
  for ps in senders.values():
    ps.invalidated = true
    let stream = move ps.stream
    if not stream.isNil():
      await stream.reset()

proc new*(
    T: typedesc[MessageSender],
    switch: Switch,
    codec: string,
    maxMsgSize: int,
    maxReuseFailures: int = DefaultMaxStreamReuseFailures,
): T {.raises: [].} =
  let ms = T(
    switch: switch,
    codec: codec,
    maxMsgSize: maxMsgSize,
    maxReuseFailures: maxReuseFailures,
  )
  # A dead connection takes its streams with it; drop the entry so the table
  # stays bounded by the number of connected peers.
  ms.onDisconnect = proc(
      peerId: PeerId, event: ConnEvent
  ) {.async: (raises: [CancelledError]).} =
    await ms.dropPeer(peerId)

  switch.addConnEventHandler(ms.onDisconnect, ConnEventKind.Disconnected)
  ms

proc senderFor(ms: MessageSender, peerId: PeerId): PeerMessageSender {.raises: [].} =
  ms.senders.mgetOrPut(peerId, PeerMessageSender(lock: newAsyncLock()))

proc forget(ms: MessageSender, peerId: PeerId, ps: PeerMessageSender) {.raises: [].} =
  ## Drop an idle entry. Peers we never reached leave no stream and raise no
  ## disconnect event, so without this the table grows with every peer id a
  ## lookup ever named.
  if ps.users > 0 or not ps.stream.isNil():
    return
  if ms.senders.getOrDefault(peerId) == ps:
    ms.senders.del(peerId)

proc releaseLock(ps: PeerMessageSender) {.raises: [].} =
  try:
    ps.lock.release()
  except AsyncLockError as e:
    raiseAssert "peer message sender lock released without acquire: " & e.msg

proc prepStream(
    ms: MessageSender,
    peerId: PeerId,
    ps: PeerMessageSender,
    addrs: seq[MultiAddress],
    deadline: Moment,
): Future[Result[PreparedStream, SendError]] {.
    async: (raises: [CancelledError]), gcsafe
.} =
  if ps.invalidated:
    return err(SendError.init(dialStage, "peer message sender invalidated"))

  let existing = ps.stream
  if not existing.isNil():
    if not (existing.closed() or existing.atEof()):
      kad_stream_reuses.inc()
      return ok((existing, true))
    await ps.discardStream(existing)

  let timeLeft = deadline.timeLeft()
  if timeLeft.isZero():
    return err(SendError.init(dialStage, "timed out before dialing"))

  # `Dialer.dial` closes whatever it opened when the dial is cancelled, so
  # neither the timeout nor a cancellation leaves a half-opened channel behind.
  let dialFut = ms.switch.dial(peerId, addrs, ms.codec)
  let dialed =
    try:
      await dialFut.withTimeout(timeLeft)
    except CancelledError as e:
      await noCancel dialFut.cancelAndWait()
      raise e
  if not dialed:
    return err(SendError.init(dialStage, "timed out dialing the peer"))

  let stream =
    try:
      await dialFut
    except DialFailedError as e:
      return err(SendError.init(dialStage, e.msg))

  # `stop` and `dropPeer` reset the peer's stream, and this one did not exist
  # yet when they ran. Sending on it would use a sender that is already gone.
  if ps.invalidated:
    await stream.reset()
    return err(SendError.init(dialStage, "peer message sender invalidated"))

  ps.stream = stream
  kad_streams_opened.inc()
  ok((stream, false))

proc exchange(
    stream: Stream,
    payload: seq[byte],
    maxMsgSize: int,
    deadline: Moment,
    awaitReply: bool,
): Future[Result[seq[byte], SendError]] {.async: (raises: [CancelledError]), gcsafe.} =
  try:
    await stream.writeLp(payload)
  except LPStreamError as e:
    return err(SendError.init(writeStage, e.msg))

  if not awaitReply:
    return ok(newSeq[byte]())

  # A reply that arrives after we stopped waiting would be read as the answer to
  # the next RPC on this stream, so a timeout always retires the stream.
  let timeLeft = deadline.timeLeft()
  if timeLeft.isZero():
    return err(SendError.init(readStage, "timed out waiting for reply"))

  let readFut = stream.readLp(maxMsgSize)
  let replied =
    try:
      await readFut.withTimeout(timeLeft)
    except CancelledError as e:
      await noCancel readFut.cancelAndWait()
      raise e
  if not replied:
    return err(SendError.init(readStage, "timed out waiting for reply"))

  try:
    ok(await readFut)
  except LPStreamError as e:
    err(SendError.init(readStage, e.msg))

proc send(
    ms: MessageSender,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    payload: sink seq[byte],
    timeout: Duration,
    awaitReply: bool,
): Future[Result[seq[byte], SendError]] {.async: (raises: [CancelledError]), gcsafe.} =
  if ms.stopped:
    return err(SendError.init(dialStage, "message sender stopped"))

  let ps = ms.senderFor(peerId)
  ps.users.inc()
  defer:
    ps.users.dec()
    ms.forget(peerId, ps)

  # One deadline covers the wait for the peer's turn and the exchange itself, so
  # an RPC gives the stream up as soon as its own budget runs out. Charging each
  # phase a full `timeout` instead would let every RPC overrun the caller's
  # deadline, and the retry the caller sends next would spend its whole budget
  # waiting for the stream, never reaching the peer.
  let deadline = Moment.now() + timeout
  # `withTimeout` on an `acquire` can drop the wait at the instant chronos hands
  # the lock off, leaving it held with no owner. Release it if the acquire won
  # that race, so a cancelled or timed-out wait never leaks the peer's lock.
  let acquireFut = ps.lock.acquire()
  try:
    if not await acquireFut.withTimeout(timeout):
      if acquireFut.completed():
        ps.releaseLock()
      return err(SendError.init(dialStage, "timed out waiting for the peer's stream"))
  except CancelledError as e:
    if acquireFut.completed():
      ps.releaseLock()
    raise e
  defer:
    ps.releaseLock()

  while true:
    let (stream, reused) = (await ms.prepStream(peerId, ps, addrs, deadline)).valueOr:
      return err(error)

    let sendRes =
      try:
        await exchange(stream, payload, ms.maxMsgSize, deadline, awaitReply)
      except CancelledError as e:
        await noCancel ps.discardStream(stream)
        raise e

    if sendRes.isErr():
      await ps.discardStream(stream)
      # A reused stream also fails when the remote quietly dropped it while it
      # sat idle; one fresh attempt tells that apart from a real RPC failure.
      # A spent deadline is not that case: the peer is slow, and a second dial
      # plus a repeat of the same RPC would only add to its load.
      if not reused or deadline.timeLeft().isZero():
        return err(sendRes.error())
      ps.reuseFailures.inc()
      kad_stream_reuse_failures.inc()
      continue

    # Keep the stream only when it is safe and worth keeping: a send that read
    # nothing back may have left a reply buffered that would desync the next
    # RPC, and a peer that keeps breaking reuse is served one stream per RPC.
    if not awaitReply or ps.reuseFailures >= ms.maxReuseFailures:
      await ps.retireStream(stream, deadline)
    return sendRes

proc sendRequest*(
    ms: MessageSender,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    payload: sink seq[byte],
    timeout: Duration,
): Future[Result[seq[byte], SendError]] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Send `payload` on the peer's stream and wait for one reply. `timeout` is the
  ## whole budget: the wait for the peer's turn on that stream comes out of it.
  await ms.send(peerId, addrs, move payload, timeout, awaitReply = true)

proc sendMessage*(
    ms: MessageSender,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    payload: sink seq[byte],
    timeout: Duration,
): Future[Result[void, SendError]] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Send `payload` without waiting for a reply. `timeout` bounds the wait for
  ## the peer's turn on its stream. The stream is retired afterwards, so a reply
  ## from a remote that does answer cannot be picked up by a later RPC.
  discard ?await ms.send(peerId, addrs, move payload, timeout, awaitReply = false)
  ok()
