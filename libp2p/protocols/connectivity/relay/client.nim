# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import times
import chronos, chronicles
import
  ./relay,
  ./messages,
  ./rconn,
  ./utils,
  ../../../peerinfo,
  ../../../switch,
  ../../../multiaddress,
  ../../../stream/connection

logScope:
  topics = "libp2p relay relay-client"

const RelayClientMsgSize = 4096

type
  RelayClientError* = object of LPError
  ReservationError* = object of RelayClientError
  RelayDialError* = object of DialFailedError
  RelayV1DialError* = object of RelayDialError
  RelayV2DialError* = object of RelayDialError
  RelayClientAddConn* = proc(
    conn: RawConn, duration: uint32, data: uint64
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).}
  RelayClient* = ref object of Relay
    onNewConnection*: RelayClientAddConn
    canHop: bool

  Rsvp* = object
    expire*: uint64 # required, Unix expiration time (UTC)
    addrs*: seq[MultiAddress] # relay address for reserving peer
    voucher*: Opt[Voucher] # optional, reservation voucher
    limitDuration*: uint32 # seconds
    limitData*: uint64 # bytes

proc sendStopError(
    stream: Stream, code: StatusV2
) {.async: (raises: [CancelledError]).} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  try:
    let msg =
      StopMessage(msgType: Opt.some(StopMessageType.Status), status: Opt.some(code))
    await stream.writeLp(encode(msg))
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    trace "failed to send stop status", description = e.msg

proc handleRelayedConnect(
    cl: RelayClient, stream: Stream, msg: StopMessage
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let
    # TODO: check the go version to see in which way this could fail
    # it's unclear in the spec
    src = msg.peer.valueOr:
      await sendStopError(stream, MalformedMessage)
      return
    limitDuration = msg.limit.get(Limit()).duration
    limitData = msg.limit.get(Limit()).data
    msg = StopMessage(msgType: Opt.some(StopMessageType.Status), status: Opt.some(Ok))

  trace "incoming relay connection", src

  if cl.onNewConnection == nil:
    await sendStopError(stream, StatusV2.ConnectionFailed)
    await stream.close()
    return
  await stream.writeLp(encode(msg))
  # This sound redundant but the callback could, in theory, be set to nil during
  # stream.writeLp so it's safer to double check
  if cl.onNewConnection != nil:
    await cl.onNewConnection(stream, limitDuration, limitData)
  else:
    await stream.close()

proc reserve*(
    cl: RelayClient, peerId: PeerId, addrs: seq[MultiAddress] = @[]
): Future[Rsvp] {.async: (raises: [ReservationError, DialFailedError, CancelledError]).} =
  let stream = await cl.switch.dial(peerId, addrs, RelayV2HopCodec)
  defer:
    await stream.close()
  let
    pb = encode(HopMessage(msgType: Opt.some(HopMessageType.Reserve)))
    msg =
      try:
        await stream.writeLp(pb)
        HopMessage.decode(await stream.readLp(RelayClientMsgSize)).tryGet()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        trace "error writing or reading reservation message", description = exc.msg
        raise newException(ReservationError, exc.msg)

  if msg.msgType.isNone or msg.msgType.get() != HopMessageType.Status:
    raise newException(ReservationError, "Unexpected relay response type")
  if msg.status.get(UnexpectedMessage) != Ok:
    raise newException(ReservationError, "Reservation failed")

  let reservation = msg.reservation.valueOr:
    raise newException(ReservationError, "Missing reservation information")
  if reservation.expire > int64.high().uint64 or
      now().utc > reservation.expire.int64.fromUnix.utc:
    raise newException(ReservationError, "Bad expiration date")
  var rsvp: Rsvp
  rsvp.expire = reservation.expire
  rsvp.addrs = reservation.addrs

  reservation.svoucher.withValue(sv):
    let svoucher = SignedVoucher.decode(sv).valueOr:
      raise newException(ReservationError, "Invalid voucher")
    if svoucher.data.relayPeerId != peerId:
      raise newException(ReservationError, "Invalid voucher PeerId")
    rsvp.voucher = Opt.some(svoucher.data)

  rsvp.limitDuration = msg.limit.get(Limit()).duration
  rsvp.limitData = msg.limit.get(Limit()).data
  rsvp

proc dialPeerV1*(
    cl: RelayClient, stream: Stream, dstPeerId: PeerId, dstAddrs: seq[MultiAddress]
): Future[RawConn] {.async: (raises: [CancelledError, RelayV1DialError]).} =
  var msg = RelayMessage(
    msgType: Opt.some(RelayType.Hop),
    srcPeer: Opt.some(
      RelayPeer(peerId: cl.switch.peerInfo.peerId, addrs: cl.switch.peerInfo.addrs)
    ),
    dstPeer: Opt.some(RelayPeer(peerId: dstPeerId, addrs: dstAddrs)),
  )

  trace "Dial peer", msgSend = msg

  try:
    await stream.writeLp(encode(msg))
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    trace "error writing hop request", description = exc.msg
    raise newException(RelayV1DialError, "error writing hop request: " & exc.msg, exc)

  let msgRcvFromRelayOpt =
    try:
      RelayMessage.decode(await stream.readLp(RelayClientMsgSize))
    except CancelledError as exc:
      raise exc
    except LPStreamError as exc:
      trace "error reading stop response", description = exc.msg
      await sendStatus(stream, StatusV1.HopCantOpenDstStream)
      raise
        newException(RelayV1DialError, "error reading stop response: " & exc.msg, exc)

  try:
    let msgRcvFromRelay = msgRcvFromRelayOpt.valueOr:
      raise newException(RelayV1DialError, "Hop can't open destination stream")
    if msgRcvFromRelay.msgType.tryGet() != RelayType.Status:
      raise newException(
        RelayV1DialError, "Hop can't open destination stream: wrong message type"
      )
    if msgRcvFromRelay.status.tryGet() != StatusV1.Success:
      raise newException(
        RelayV1DialError, "Hop can't open destination stream: status failed"
      )
  except RelayV1DialError as exc:
    await sendStatus(stream, StatusV1.HopCantOpenDstStream)
    raise newException(
      RelayV1DialError,
      "Hop can't open destination stream after sendStatus: " & exc.msg,
      exc,
    )
  except ValueError as exc:
    await sendStatus(stream, StatusV1.HopCantOpenDstStream)
    raise newException(
      RelayV1DialError, "Exception reading msg in dialPeerV1: " & exc.msg, exc
    )
  stream

proc dialPeerV2*(
    cl: RelayClient,
    relayConn: RelayConnection,
    dstPeerId: PeerId,
    dstAddrs: seq[MultiAddress],
): Future[RawConn] {.async: (raises: [RelayV2DialError, CancelledError]).} =
  let p = Peer(peerId: dstPeerId, addrs: dstAddrs)

  trace "Dial peer", p

  let msgRcvFromRelay =
    try:
      await relayConn.writeLp(
        encode(HopMessage(msgType: Opt.some(HopMessageType.Connect), peer: Opt.some(p)))
      )
      HopMessage.decode(await relayConn.readLp(RelayClientMsgSize)).tryGet()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "error reading stop response", description = exc.msg
      raise
        newException(RelayV2DialError, "Exception decoding HopMessage: " & exc.msg, exc)

  if msgRcvFromRelay.msgType.isNone or
      msgRcvFromRelay.msgType != Opt.some(HopMessageType.Status):
    raise newException(RelayV2DialError, "Unexpected stop response")
  if msgRcvFromRelay.status.get(UnexpectedMessage) != Ok:
    trace "Relay stop failed", description = msgRcvFromRelay.status
    raise newException(RelayV2DialError, "Relay stop failure")
  relayConn.limitDuration = msgRcvFromRelay.limit.get(Limit()).duration
  relayConn.limitData = msgRcvFromRelay.limit.get(Limit()).data
  return relayConn

proc handleStopStreamV2(
    cl: RelayClient, stream: Stream
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = StopMessage.decode(await stream.readLp(RelayClientMsgSize)).valueOr:
    await sendHopStatus(stream, MalformedMessage)
    return
  trace "client circuit relay v2 handle stream", msg

  if msg.msgType.isSome and msg.msgType.get() == StopMessageType.Connect:
    await cl.handleRelayedConnect(stream, msg)
  else:
    trace "Unexpected client / relayv2 handshake", msgType = msg.msgType
    await sendStopError(stream, MalformedMessage)

proc handleStop(
    cl: RelayClient, stream: Stream, msg: RelayMessage
) {.async: (raises: [CancelledError]).} =
  let src = msg.srcPeer.valueOr:
    await sendStatus(stream, StatusV1.StopSrcMultiaddrInvalid)
    return

  let dst = msg.dstPeer.valueOr:
    await sendStatus(stream, StatusV1.StopDstMultiaddrInvalid)
    return

  if dst.peerId != cl.switch.peerInfo.peerId:
    await sendStatus(stream, StatusV1.StopDstMultiaddrInvalid)
    return

  trace "get a relay connection", src, stream

  if cl.onNewConnection == nil:
    await sendStatus(stream, StatusV1.StopRelayRefused)
    await stream.close()
    return
  await sendStatus(stream, StatusV1.Success)
  # This sound redundant but the callback could, in theory, be set to nil during
  # sendStatus(Success) so it's safer to double check
  if cl.onNewConnection != nil:
    await cl.onNewConnection(stream, 0, 0)
  else:
    await stream.close()

proc handleStreamV1(
    cl: RelayClient, stream: Stream
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = RelayMessage.decode(await stream.readLp(RelayClientMsgSize)).valueOr:
    await sendStatus(stream, StatusV1.MalformedMessage)
    return
  trace "client circuit relay v1 handle stream", msg

  let typ = msg.msgType.valueOr:
    trace "Message type not set"
    await sendStatus(stream, StatusV1.MalformedMessage)
    return
  case typ
  of RelayType.Hop:
    if cl.canHop:
      await cl.handleHop(stream, msg)
    else:
      await sendStatus(stream, StatusV1.HopCantSpeakRelay)
  of RelayType.Stop:
    await cl.handleStop(stream, msg)
  of RelayType.CanHop:
    if cl.canHop:
      await sendStatus(stream, StatusV1.Success)
    else:
      await sendStatus(stream, StatusV1.HopCantSpeakRelay)
  else:
    trace "Unexpected relay handshake", msgType = msg.msgType
    await sendStatus(stream, StatusV1.MalformedMessage)

proc new*(
    T: typedesc[RelayClient],
    canHop: bool = false,
    reservationTTL: times.Duration = DefaultReservationTTL,
    limitDuration: uint32 = DefaultLimitDuration,
    limitData: uint64 = DefaultLimitData,
    heartbeatSleepTime: uint32 = DefaultHeartbeatSleepTime,
    maxCircuit: int = MaxCircuit,
    maxCircuitPerPeer: int = MaxCircuitPerPeer,
    msgSize: int = RelayClientMsgSize,
    circuitRelayV1: bool = false,
): T =
  let cl = T(
    canHop: canHop,
    reservationTTL: reservationTTL,
    limit: Limit(duration: limitDuration, data: limitData),
    heartbeatSleepTime: heartbeatSleepTime,
    maxCircuit: maxCircuit,
    maxCircuitPerPeer: maxCircuitPerPeer,
    msgSize: msgSize,
    isCircuitRelayV1: circuitRelayV1,
  )
  proc handleStream(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      case proto
      of RelayV1Codec:
        await cl.handleStreamV1(stream)
      of RelayV2StopCodec:
        await cl.handleStopStreamV2(stream)
      of RelayV2HopCodec:
        await cl.handleHopStreamV2(stream)
    except CancelledError as exc:
      trace "cancelled client handler"
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", description = exc.msg, stream
    finally:
      trace "exiting client handler", stream
      await stream.close()

  cl.handler = handleStream
  cl.codecs =
    if cl.canHop:
      @[RelayV1Codec, RelayV2HopCodec, RelayV2StopCodec]
    else:
      @[RelayV1Codec, RelayV2StopCodec]
  cl
