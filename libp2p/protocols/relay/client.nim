## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles, options
import ./messages,
       ./rconn,
       ./utils,
       ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../stream/connection

import std/times

logScope:
  topics = "libp2p circuit relay client"

const ClientMsgSize = 4096

type
  ClientError* = object of LPError
  ReservationError* = object of ClientError
  RelayV1DialError* = object of ClientError
  RelayV2DialError* = object of ClientError
  ClientAddConn* = proc(conn: Connection,
                        duration: uint32,
                        data: uint64): Future[void] {.gcsafe, raises: [Defect].}
  Client* = ref object of LPProtocol
    switch*: Switch
    addConn*: ClientAddConn

  Rsvp* = object
    expire*: uint64           # required, Unix expiration time (UTC)
    addrs*: seq[MultiAddress] # relay address for reserving peer
    voucher*: Option[Voucher] # optional, reservation voucher
    limitDuration*: uint32    # seconds
    limitData*: uint64        # bytes

proc sendStopError(conn: Connection, code: StatusV2) {.async.} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  let msg = StopMessage(msgType: StopMessageType.Status, status: some(code))
  await conn.writeLp(encode(msg).buffer)

proc handleConnect(cl: Client, conn: Connection, msg: StopMessage) {.async.} =
  if msg.peer.isNone():
    await sendStopError(conn, MalformedMessage)
    return
  let
    # TODO: check the go version to see in which way this could fail
    # it's unclear in the spec
    src = msg.peer.get()
    limitDuration = msg.limit.duration
    limitData = msg.limit.data
    msg = StopMessage(
      msgType: StopMessageType.Status,
      status: some(Ok))
    pb = encode(msg)

  trace "incoming relay connection", src

  if cl.addConn == nil:
    await sendStopError(conn, StatusV2.ConnectionFailed)
    await conn.close()
    return
  await conn.writeLp(pb.buffer)
  # This sound redundant but the callback could, in theory, be set to nil during
  # conn.writeLp so it's safer to double check
  if cl.addConn != nil: await cl.addConn(conn, limitDuration, limitData)
  else: await conn.close()

proc reserve*(cl: Client, peerId: PeerId, addrs: seq[MultiAddress]): Future[Rsvp] {.async.} =
  let conn = await cl.switch.dial(peerId, addrs, RelayV2HopCodec)
  defer: await conn.close()
  let
    pb = encode(HopMessage(msgType: HopMessageType.Reserve))
    msg = try:
      await conn.writeLp(pb.buffer)
      HopMessage.decode(await conn.readLp(ClientMsgSize)).get()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "error writing or reading reservation message", exc=exc.msg
      raise newException(ReservationError, exc.msg)

  if msg.msgType != HopMessageType.Status:
    raise newException(ReservationError, "Unexpected relay response type")
  if msg.status.get(UnexpectedMessage) != Ok:
    raise newException(ReservationError, "Reservation failed")
  if msg.reservation.isNone():
    raise newException(ReservationError, "Missing reservation information")

  let reservation = msg.reservation.get()
  if now().utc > reservation.expire.int64.fromUnix.utc:
    raise newException(ReservationError, "Bad expiration date")
  result.expire = reservation.expire
  result.addrs = reservation.addrs

  if reservation.svoucher.isSome():
    let svoucher = SignedVoucher.decode(reservation.svoucher.get())
    if svoucher.isErr() or svoucher.get().data.relayPeerId != peerId:
      raise newException(ReservationError, "Invalid voucher")
    result.voucher = some(svoucher.get().data)

  result.limitDuration = msg.limit.duration
  result.limitData = msg.limit.data

proc dialPeerV1*(
    cl: Client,
    conn: Connection,
    dstPeerId: PeerId,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  var
    msg = RelayMessage(
      msgType: some(RelayType.Hop),
      srcPeer: some(RelayPeer(peerId: cl.switch.peerInfo.peerId, addrs: cl.switch.peerInfo.addrs)),
      dstPeer: some(RelayPeer(peerId: dstPeerId, addrs: dstAddrs)))
    pb = encode(msg)

  trace "Dial peer", msgSend=msg

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing hop request", exc=exc.msg
    raise exc

  let msgRcvFromRelayOpt = try:
    RelayMessage.decode(await conn.readLp(ClientMsgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise exc

  if msgRcvFromRelayOpt.isNone:
    trace "error reading stop response", msg = msgRcvFromRelayOpt
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(RelayV1DialError, "Hop can't open destination stream")

  let msgRcvFromRelay = msgRcvFromRelayOpt.get()
  if msgRcvFromRelay.msgType.isNone or msgRcvFromRelay.msgType.get() != RelayType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromRelay.msgType
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(RelayV1DialError, "Hop can't open destination stream")

  if msgRcvFromRelay.status.isNone or msgRcvFromRelay.status.get() != StatusV1.Success:
    trace "relay stop failure", status=msgRcvFromRelay.status
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(RelayV1DialError, "Hop can't open destination stream")
  result = conn

proc dialPeerV2*(
    cl: Client,
    conn: RelayConnection,
    dstPeerId: PeerID,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  let
    p = Peer(peerId: dstPeerId, addrs: dstAddrs)
    pb = encode(HopMessage(msgType: HopMessageType.Connect, peer: some(p)))

  trace "Dial peer", p

  let msgRcvFromRelay = try:
    await conn.writeLp(pb.buffer)
    HopMessage.decode(await conn.readLp(ClientMsgSize)).get()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    raise newException(RelayV2DialError, exc.msg)

  if msgRcvFromRelay.msgType != HopMessageType.Status:
    raise newException(RelayV2DialError, "Unexpected stop response")
  if msgRcvFromRelay.status.get(UnexpectedMessage) != Ok:
    trace "Relay stop failed", msg = msgRcvFromRelay.status.get()
    raise newException(RelayV2DialError, "Relay stop failure")
  conn.limitDuration = msgRcvFromRelay.limit.duration
  conn.limitData = msgRcvFromRelay.limit.data
  return conn

proc handleStreamV2(cl: Client, conn: Connection) {.async, gcsafe.} =
  let msgOpt = StopMessage.decode(await conn.readLp(ClientMsgSize))
  if msgOpt.isNone():
    await sendHopStatus(conn, MalformedMessage)
    return
  trace "client circuit relay v2 handle stream", msg = msgOpt.get()
  let msg = msgOpt.get()

  if msg.msgType == StopMessageType.Connect:
    await cl.handleConnect(conn, msg)
  else:
    trace "Unexpected client / relayv2 handshake", msgType=msg.msgType
    await sendStopError(conn, MalformedMessage)

proc handleStop(cl: Client, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  if msg.srcPeer.isNone:
    await sendStatus(conn, StatusV1.StopSrcMultiaddrInvalid)
    return
  let src = msg.srcPeer.get()

  if msg.dstPeer.isNone:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  let dst = msg.dstPeer.get()
  if dst.peerId != cl.switch.peerInfo.peerId:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  trace "get a relay connection", src, conn

  if cl.addConn == nil:
    await sendStatus(conn, StatusV1.StopRelayRefused)
    await conn.close()
    return
  await sendStatus(conn, StatusV1.Success)
  # This sound redundant but the callback could, in theory, be set to nil during
  # sendStatus(Success) so it's safer to double check
  if cl.addConn != nil: await cl.addConn(conn, 0, 0)
  else: await conn.close()

proc handleStreamV1(cl: Client, conn: Connection) {.async, gcsafe.} =
  let msgOpt = RelayMessage.decode(await conn.readLp(ClientMsgSize))
  if msgOpt.isNone:
    await sendStatus(conn, StatusV1.MalformedMessage)
    return
  trace "client circuit relay v1 handle stream", msg = msgOpt.get()
  let msg = msgOpt.get()
  case msg.msgType.get:
    of RelayType.Hop: await sendStatus(conn, StatusV1.HopCantSpeakRelay)
    of RelayType.Stop: await cl.handleStop(conn, msg)
    of RelayType.CanHop: await sendStatus(conn, StatusV1.HopCantSpeakRelay)
    else:
      trace "Unexpected relay handshake", msgType=msg.msgType
      await sendStatus(conn, StatusV1.MalformedMessage)

proc setup*(cl: Client, switch: Switch) =
  cl.switch = switch

proc new*(T: typedesc[Client]): T =
  let cl = T()
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      case proto:
      of RelayV1Codec: await cl.handleStreamV1(conn)
      of RelayV2StopCodec: await cl.handleStreamV2(conn)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", exc = exc.msg, conn
    finally:
      trace "exiting client handler", conn
      await conn.close()

  cl.handler = handleStream
  cl.codecs = @[RelayV1Codec, RelayV2StopCodec]
  cl
