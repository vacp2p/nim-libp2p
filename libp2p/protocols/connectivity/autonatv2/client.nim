# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import results
import chronos, chronicles, tables
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
  ../../../protobuf/minprotobuf,
  ./types,
  ./utils

logScope:
  topics = "libp2p autonat v2 client"

const
  MaxAcceptedDialDataRequest* = 100 * 1024 # 100 KB
  MaxDialDataResponsePayload* = 1024
  DefaultDialBackTimeout* = 5.seconds

type AutonatV2Client* = ref object of LPProtocol
  dialer*: Dial
  dialBackTimeout: Duration
  rng: ref HmacDrbgContext
  expectedNonces: Table[Nonce, Opt[MultiAddress]]

proc handleDialBack(
    self: AutonatV2Client, conn: Connection, dialBack: DialBack
) {.async: (raises: [CancelledError, AutonatV2Error, LPStreamError]).} =
  debug "Handling DialBack",
    conn = conn, localAddr = conn.localAddr, observedAddr = conn.observedAddr

  if not self.expectedNonces.hasKey(dialBack.nonce):
    error "Not expecting this nonce", nonce = dialBack.nonce
    return

  conn.localAddr.withValue(localAddr):
    debug "Setting expectedNonces",
      nonce = dialBack.nonce, localAddr = Opt.some(localAddr)
    self.expectedNonces[dialBack.nonce] = Opt.some(localAddr)
  else:
    error "Unable to get localAddr from connection"
    return

  trace "Sending DialBackResponse"
  await conn.writeLp(DialBackResponse(status: DialBackStatus.Ok).encode().buffer)

proc new*(
    T: typedesc[AutonatV2Client],
    rng: ref HmacDrbgContext,
    dialBackTimeout: Duration = DefaultDialBackTimeout,
): T =
  let client = T(rng: rng, dialBackTimeout: dialBackTimeout)

  # handler for DialBack messages
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let dialBack = DialBack.decode(initProtoBuffer(await conn.readLp(DialBackLpSize))).valueOr:
        trace "Unable to decode DialBack"
        return
      if not await client.handleDialBack(conn, dialBack).withTimeout(
        client.dialBackTimeout
      ):
        trace "Sending DialBackResponse timed out"
    except CancelledError as exc:
      raise exc
    except LPStreamRemoteClosedError as exc:
      debug "Connection closed by peer", description = exc.msg, peer = conn.peerId
    except LPStreamError as exc:
      debug "Connection closed by peer", description = exc.msg, peer = conn.peerId

  client.handler = handleStream
  client.codec = $AutonatV2Codec.DialBack
  client

proc setup*(self: AutonatV2Client, switch: Switch) =
  self.dialer = switch.dialer

proc handleDialDataRequest*(
    conn: Connection, req: DialDataRequest
): Future[DialResponse] {.
    async: (raises: [CancelledError, AutonatV2Error, LPStreamError])
.} =
  debug "Received DialDataRequest",
    numBytes = req.numBytes, maxAcceptedNumBytes = MaxAcceptedDialDataRequest

  if req.numBytes > MaxAcceptedDialDataRequest:
    raise newException(
      AutonatV2Error, "Rejecting DialDataRequest: numBytes is greater than the maximum"
    )

  # send required data
  var msg = AutonatV2Msg(
    msgType: MsgType.DialDataResponse,
    dialDataResp: DialDataResponse(data: newSeq[byte](MaxDialDataResponsePayload)),
  )
  let messagesToSend =
    (req.numBytes + MaxDialDataResponsePayload - 1) div MaxDialDataResponsePayload
  for i in 0 ..< messagesToSend:
    await conn.writeLp(msg.encode().buffer)
    debug "Sending DialDataResponse", i = i, messagesToSend = messagesToSend

  # get DialResponse
  msg = AutonatV2Msg.decode(initProtoBuffer(await conn.readLp(AutonatV2MsgLpSize))).valueOr:
    raise newException(AutonatV2Error, "Unable to decode AutonatV2Msg")

  debug "Received message", msgType = msg.msgType
  if msg.msgType != MsgType.DialResponse:
    raise
      newException(AutonatV2Error, "Expecting DialResponse, but got " & $msg.msgType)

  return msg.dialResp

proc checkAddrIdx(
    self: AutonatV2Client, addrIdx: AddrIdx, testAddrs: seq[MultiAddress], nonce: Nonce
): bool {.raises: [AutonatV2Error].} =
  debug "checking addrs", addrIdx = addrIdx, testAddrs = testAddrs, nonce = nonce
  let dialBackAddrs = self.expectedNonces.getOrDefault(nonce).valueOr:
    debug "Not expecting this nonce",
      nonce = nonce, expectedNonces = self.expectedNonces
    return false

  if addrIdx.int >= testAddrs.len:
    debug "addrIdx outside of testAddrs range",
      addrIdx = addrIdx, testAddrs = testAddrs, testAddrsLen = testAddrs.len
    return false

  let dialRespAddrs = testAddrs[addrIdx]
  if not areAddrsConsistent(dialRespAddrs, dialBackAddrs):
    debug "Invalid addrIdx: got DialBack in another address",
      addrIdx = addrIdx, dialBackAddrs = dialBackAddrs, dialRespAddrs = dialRespAddrs
    return false
  true

method sendDialRequest*(
    self: AutonatV2Client, pid: PeerId, testAddrs: seq[MultiAddress]
): Future[AutonatV2Response] {.
    base,
    async: (raises: [AutonatV2Error, CancelledError, DialFailedError, LPStreamError])
.} =
  ## Dials peer with `pid` and requests that it tries connecting to `testAddrs`

  let nonce = self.rng[].generate(Nonce)
  self.expectedNonces[nonce] = Opt.none(MultiAddress)

  var dialResp: DialResponse
  try:
    let conn = await self.dialer.dial(pid, @[$AutonatV2Codec.DialRequest])
    defer:
      await conn.close()

    # send dialRequest
    await conn.writeLp(
      AutonatV2Msg(
        msgType: MsgType.DialRequest,
        dialReq: DialRequest(addrs: testAddrs, nonce: nonce),
      ).encode().buffer
    )
    let msg = AutonatV2Msg.decode(
      initProtoBuffer(await conn.readLp(AutonatV2MsgLpSize))
    ).valueOr:
      raise newException(AutonatV2Error, "Unable to decode AutonatV2Msg")

    dialResp =
      case msg.msgType
      of MsgType.DialResponse:
        msg.dialResp
      of MsgType.DialDataRequest:
        await conn.handleDialDataRequest(msg.dialDataReq)
      else:
        raise newException(
          AutonatV2Error,
          "Expecting DialResponse or DialDataRequest, but got " & $msg.msgType,
        )
    debug "Received DialResponse", dialResp = dialResp

    dialResp.dialStatus.withValue(dialStatus):
      if dialStatus == DialStatus.Ok:
        dialResp.addrIdx.withValue(addrIdx):
          if not self.checkAddrIdx(addrIdx, testAddrs, nonce):
            raise newException(
              AutonatV2Error, "Invalid addrIdx " & $addrIdx & " in DialResponse"
            )
  except LPStreamRemoteClosedError as exc:
    error "Stream reset by server", description = exc.msg, peer = pid
  finally:
    # rollback any changes
    self.expectedNonces.del(nonce)
  return dialResp.asAutonatV2Response(testAddrs)
