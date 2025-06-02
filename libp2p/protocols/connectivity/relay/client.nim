# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
    conn: Connection, duration: uint32, data: uint64
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
    conn: Connection, code: StatusV2
) {.async: (raises: [CancelledError]).} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  try:
    let msg = StopMessage(msgType: StopMessageType.Status, status: Opt.some(code))
    await conn.writeLp(encode(msg).buffer)
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    trace "failed to send stop status", description = e.msg

proc handleRelayedConnect(
    cl: RelayClient, conn: Connection, msg: StopMessage
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let
    # TODO: check the go version to see in which way this could fail
    # it's unclear in the spec
    src = msg.peer.valueOr:
      await sendStopError(conn, MalformedMessage)
      return
    limitDuration = msg.limit.duration
    limitData = msg.limit.data
    msg = StopMessage(msgType: StopMessageType.Status, status: Opt.some(Ok))
    pb = encode(msg)

  trace "incoming relay connection", src

  if cl.onNewConnection == nil:
    await sendStopError(conn, StatusV2.ConnectionFailed)
    await conn.close()
    return
  await conn.writeLp(pb.buffer)
  # This sound redundant but the callback could, in theory, be set to nil during
  # conn.writeLp so it's safer to double check
  if cl.onNewConnection != nil:
    await cl.onNewConnection(conn, limitDuration, limitData)
  else:
    await conn.close()

proc reserve*(
    cl: RelayClient, peerId: PeerId, addrs: seq[MultiAddress] = @[]
): Future[Rsvp] {.async: (raises: [ReservationError, DialFailedError, CancelledError]).} =
  let conn = await cl.switch.dial(peerId, addrs, RelayV2HopCodec)
  defer:
    await conn.close()
  let
    pb = encode(HopMessage(msgType: HopMessageType.Reserve))
    msg =
      try:
        await conn.writeLp(pb.buffer)
        HopMessage.decode(await conn.readLp(RelayClientMsgSize)).tryGet()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        trace "error writing or reading reservation message", description = exc.msg
        raise newException(ReservationError, exc.msg)

  if msg.msgType != HopMessageType.Status:
    raise newException(ReservationError, "Unexpected relay response type")
  if msg.status.get(UnexpectedMessage) != Ok:
    raise newException(ReservationError, "Reservation failed")

  let reservation = msg.reservation.valueOr:
    raise newException(ReservationError, "Missing reservation information")
  if reservation.expire > int64.high().uint64 or
      now().utc > reservation.expire.int64.fromUnix.utc:
    raise newException(ReservationError, "Bad expiration date")
  result.expire = reservation.expire
  result.addrs = reservation.addrs

  reservation.svoucher.withValue(sv):
    let svoucher = SignedVoucher.decode(sv).valueOr:
      raise newException(ReservationError, "Invalid voucher")
    if svoucher.data.relayPeerId != peerId:
      raise newException(ReservationError, "Invalid voucher PeerId")
    result.voucher = Opt.some(svoucher.data)

  result.limitDuration = msg.limit.duration
  result.limitData = msg.limit.data

proc dialPeerV1*(
    cl: RelayClient, conn: Connection, dstPeerId: PeerId, dstAddrs: seq[MultiAddress]
): Future[Connection] {.async: (raises: [CancelledError, RelayV1DialError]).} =
  var
    msg = RelayMessage(
      msgType: Opt.some(RelayType.Hop),
      srcPeer: Opt.some(
        RelayPeer(peerId: cl.switch.peerInfo.peerId, addrs: cl.switch.peerInfo.addrs)
      ),
      dstPeer: Opt.some(RelayPeer(peerId: dstPeerId, addrs: dstAddrs)),
    )
    pb = encode(msg)

  trace "Dial peer", msgSend = msg

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise newException(
      CancelledError, "Cancelled while writing dialPeerV1: " & exc.msg, exc
    )
  except LPStreamError as exc:
    trace "error writing hop request", description = exc.msg
    raise newException(RelayV1DialError, "error writing hop request: " & exc.msg, exc)

  let msgRcvFromRelayOpt =
    try:
      RelayMessage.decode(await conn.readLp(RelayClientMsgSize))
    except CancelledError as exc:
      raise newException(
        CancelledError, "Cancelled while reading stop response: " & exc.msg, exc
      )
    except LPStreamError as exc:
      trace "error reading stop response", description = exc.msg
      await sendStatus(conn, StatusV1.HopCantOpenDstStream)
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
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(
      RelayV1DialError,
      "Hop can't open destination stream after sendStatus: " & exc.msg,
      exc,
    )
  except ValueError as exc:
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(
      RelayV1DialError, "Exception reading msg in dialPeerV1: " & exc.msg, exc
    )
  result = conn

proc dialPeerV2*(
    cl: RelayClient,
    conn: RelayConnection,
    dstPeerId: PeerId,
    dstAddrs: seq[MultiAddress],
): Future[Connection] {.async: (raises: [RelayV2DialError, CancelledError]).} =
  let
    p = Peer(peerId: dstPeerId, addrs: dstAddrs)
    pb = encode(HopMessage(msgType: HopMessageType.Connect, peer: Opt.some(p)))

  trace "Dial peer", p

  let msgRcvFromRelay =
    try:
      await conn.writeLp(pb.buffer)
      HopMessage.decode(await conn.readLp(RelayClientMsgSize)).tryGet()
    except CancelledError as exc:
      raise newException(
        CancelledError, "Cancelled while writing dialPeerV2: " & exc.msg, exc
      )
    except CatchableError as exc:
      trace "error reading stop response", description = exc.msg
      raise
        newException(RelayV2DialError, "Exception decoding HopMessage: " & exc.msg, exc)

  if msgRcvFromRelay.msgType != HopMessageType.Status:
    raise newException(RelayV2DialError, "Unexpected stop response")
  if msgRcvFromRelay.status.get(UnexpectedMessage) != Ok:
    trace "Relay stop failed", description = msgRcvFromRelay.status
    raise newException(RelayV2DialError, "Relay stop failure")
  conn.limitDuration = msgRcvFromRelay.limit.duration
  conn.limitData = msgRcvFromRelay.limit.data
  return conn

proc handleStopStreamV2(
    cl: RelayClient, conn: Connection
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = StopMessage.decode(await conn.readLp(RelayClientMsgSize)).valueOr:
    await sendHopStatus(conn, MalformedMessage)
    return
  trace "client circuit relay v2 handle stream", msg

  if msg.msgType == StopMessageType.Connect:
    await cl.handleRelayedConnect(conn, msg)
  else:
    trace "Unexpected client / relayv2 handshake", msgType = msg.msgType
    await sendStopError(conn, MalformedMessage)

proc handleStop(
    cl: RelayClient, conn: Connection, msg: RelayMessage
) {.async: (raises: [CancelledError]).} =
  let src = msg.srcPeer.valueOr:
    await sendStatus(conn, StatusV1.StopSrcMultiaddrInvalid)
    return

  let dst = msg.dstPeer.valueOr:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  if dst.peerId != cl.switch.peerInfo.peerId:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  trace "get a relay connection", src, conn

  if cl.onNewConnection == nil:
    await sendStatus(conn, StatusV1.StopRelayRefused)
    await conn.close()
    return
  await sendStatus(conn, StatusV1.Success)
  # This sound redundant but the callback could, in theory, be set to nil during
  # sendStatus(Success) so it's safer to double check
  if cl.onNewConnection != nil:
    await cl.onNewConnection(conn, 0, 0)
  else:
    await conn.close()

proc handleStreamV1(
    cl: RelayClient, conn: Connection
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = RelayMessage.decode(await conn.readLp(RelayClientMsgSize)).valueOr:
    await sendStatus(conn, StatusV1.MalformedMessage)
    return
  trace "client circuit relay v1 handle stream", msg

  let typ = msg.msgType.valueOr:
    trace "Message type not set"
    await sendStatus(conn, StatusV1.MalformedMessage)
    return
  case typ
  of RelayType.Hop:
    if cl.canHop:
      await cl.handleHop(conn, msg)
    else:
      await sendStatus(conn, StatusV1.HopCantSpeakRelay)
  of RelayType.Stop:
    await cl.handleStop(conn, msg)
  of RelayType.CanHop:
    if cl.canHop:
      await sendStatus(conn, StatusV1.Success)
    else:
      await sendStatus(conn, StatusV1.HopCantSpeakRelay)
  else:
    trace "Unexpected relay handshake", msgType = msg.msgType
    await sendStatus(conn, StatusV1.MalformedMessage)

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
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      case proto
      of RelayV1Codec:
        await cl.handleStreamV1(conn)
      of RelayV2StopCodec:
        await cl.handleStopStreamV2(conn)
      of RelayV2HopCodec:
        await cl.handleHopStreamV2(conn)
    except CancelledError as exc:
      trace "cancelled client handler"
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", description = exc.msg, conn
    finally:
      trace "exiting client handler", conn
      await conn.close()

  cl.handler = handleStream
  cl.codecs =
    if cl.canHop:
      @[RelayV1Codec, RelayV2HopCodec, RelayV2StopCodec]
    else:
      @[RelayV1Codec, RelayV2StopCodec]
  cl
