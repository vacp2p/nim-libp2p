# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import results
import chronos, chronicles, tables
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
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
  rng: Rng
  expectedNonces: Table[Nonce, Opt[MultiAddress]]

proc handleDialBack(
    self: AutonatV2Client, stream: Stream, dialBack: DialBack
) {.async: (raises: [CancelledError, AutonatV2Error, LPStreamError]).} =
  debug "Handling DialBack",
    stream = stream, localAddr = stream.localAddr, observedAddr = stream.observedAddr

  if not self.expectedNonces.hasKey(dialBack.nonce):
    error "Not expecting this nonce", nonce = dialBack.nonce
    return

  stream.localAddr.withValue(localAddr):
    debug "Setting expectedNonces",
      nonce = dialBack.nonce, localAddr = Opt.some(localAddr)
    self.expectedNonces[dialBack.nonce] = Opt.some(localAddr)
  else:
    error "Unable to get localAddr from connection"
    return

  trace "Sending DialBackResponse"
  await stream.writeLp(DialBackResponse(status: DialBackStatus.Ok).encode())

proc new*(
    T: typedesc[AutonatV2Client],
    rng: Rng,
    dialBackTimeout: Duration = DefaultDialBackTimeout,
): T =
  let client = T(rng: rng, dialBackTimeout: dialBackTimeout)

  # handler for DialBack messages
  proc handleStream(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let dialBack = DialBack.decode(await stream.readLp(DialBackLpSize)).valueOr:
        trace "Unable to decode DialBack", error = error
        return
      if not await client.handleDialBack(stream, dialBack).withTimeout(
        client.dialBackTimeout
      ):
        trace "Sending DialBackResponse timed out"
    except CancelledError as exc:
      raise exc
    except LPStreamRemoteClosedError as exc:
      debug "Stream closed by peer", description = exc.msg, peer = stream.peerId
    except LPStreamError as exc:
      debug "Stream closed by peer", description = exc.msg, peer = stream.peerId

  client.handler = handleStream
  client.codec = $AutonatV2Codec.DialBack
  client

proc setup*(self: AutonatV2Client, switch: Switch) =
  self.dialer = switch.dialer

proc handleDialDataRequest*(
    stream: Stream, req: DialDataRequest
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
    oneof: AutonatV2MsgOneof(
      kind: MsgKind.DialDataResponse,
      dialDataResponse: DialDataResponse(data: newSeq[byte](MaxDialDataResponsePayload)),
    )
  )
  let messagesToSend =
    (req.numBytes + MaxDialDataResponsePayload - 1) div MaxDialDataResponsePayload
  for i in 0 ..< messagesToSend:
    await stream.writeLp(msg.encode())
    debug "Sending DialDataResponse", i = i, messagesToSend = messagesToSend

  # get DialResponse
  msg = AutonatV2Msg.decode(await stream.readLp(AutonatV2MsgLpSize)).valueOr:
    raise newException(AutonatV2Error, error)

  debug "Received message"

  return msg.oneof.dialResponse

proc checkAddrIdx(
    self: AutonatV2Client, addrIdx: AddrIdx, testAddrs: seq[MultiAddress], nonce: Nonce
): bool {.raises: [].} =
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

  let nonce = self.rng.generate(Nonce)
  self.expectedNonces[nonce] = Opt.none(MultiAddress)

  var dialResp: DialResponse
  try:
    let stream = await self.dialer.dial(pid, @[$AutonatV2Codec.DialRequest])
    defer:
      await stream.close()

    # send dialRequest
    await stream.writeLp(
      AutonatV2Msg(
        oneof: AutonatV2MsgOneof(
          kind: MsgKind.DialRequest,
          dialRequest: DialRequest(addrs: testAddrs, nonce: nonce),
        )
      ).encode()
    )
    let msg = AutonatV2Msg.decode(await stream.readLp(AutonatV2MsgLpSize)).valueOr:
      raise newException(AutonatV2Error, error)

    dialResp =
      case msg.oneof.kind
      of MsgKind.DialResponse:
        msg.oneof.dialResponse
      of MsgKind.DialDataRequest:
        await stream.handleDialDataRequest(msg.oneof.dialDataRequest)
      else:
        raise newException(
          AutonatV2Error,
          "Expecting DialResponse or DialDataRequest, but got " & $msg.oneof.kind,
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
