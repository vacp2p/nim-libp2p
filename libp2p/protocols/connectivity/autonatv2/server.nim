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
import chronos, chronicles
import
  ../../../../libp2p/[
    switch,
    muxers/muxer,
    dialer,
    multiaddress,
    transports/transport,
    multicodec,
    peerid,
    protobuf/minprotobuf,
    utils/ipaddr,
  ],
  ../../protocol,
  ./types

logScope:
  topics = "libp2p autonat v2 server"

const
  DefaultDialTimeout: Duration = 15.seconds
  DefaultAmplificationAttackDialTimeout: Duration = 3.seconds
  DefaultDialDataSize: uint64 = 50 * 1024 # 50 KiB > 50 KB
  AutonatV2MsgLpSize: int = 1024
  # readLp needs to receive more than 4096 bytes (since it's a DialDataResponse) + overhead
  AutonatV2DialDataResponseLpSize: int = 5000

type AutonatV2* = ref object of LPProtocol
  switch*: Switch
  dialTimeout: Duration
  dialDataSize: uint64
  amplificationAttackTimeout: Duration

proc sendDialResponse(
    conn: Connection,
    status: ResponseStatus,
    addrIdx: Opt[AddrIdx] = Opt.none(AddrIdx),
    dialStatus: Opt[DialStatus] = Opt.none(DialStatus),
) {.async: (raises: [CancelledError, LPStreamError]).} =
  await conn.writeLp(
    AutonatV2Msg(
      msgType: MsgType.DialResponse,
      dialResp: DialResponse(status: status, addrIdx: addrIdx, dialStatus: dialStatus),
    ).encode().buffer
  )

proc findObservedIPAddr*(
    conn: Connection, req: DialRequest
): Future[Opt[MultiAddress]] {.async: (raises: [CancelledError, LPStreamError]).} =
  let observedAddr = conn.observedAddr.valueOr:
    await conn.sendDialResponse(ResponseStatus.EInternalError)
    return Opt.none(MultiAddress)

  let isRelayed = observedAddr.contains(multiCodec("p2p-circuit")).valueOr:
    error "Invalid observed address"
    await conn.sendDialResponse(ResponseStatus.EDialRefused)
    return Opt.none(MultiAddress)

  if isRelayed:
    error "Invalid observed address: relayed address"
    await conn.sendDialResponse(ResponseStatus.EDialRefused)
    return Opt.none(MultiAddress)

  let hostIp = observedAddr[0].valueOr:
    error "Invalid observed address"
    await conn.sendDialResponse(ResponseStatus.EInternalError)
    return Opt.none(MultiAddress)

  return Opt.some(hostIp)

proc dialBack(
    conn: Connection, nonce: Nonce
): Future[DialStatus] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  try:
    # send dial back
    await conn.writeLp(DialBack(nonce: nonce).encode().buffer)

    # receive DialBackResponse
    let dialBackResp = DialBackResponse.decode(
      initProtoBuffer(await conn.readLp(AutonatV2MsgLpSize))
    ).valueOr:
      error "DialBack failed, could not decode DialBackResponse"
      return DialStatus.EDialBackError
  except LPStreamRemoteClosedError as exc:
    # failed because of nonce error (remote reset the stream): EDialBackError
    error "DialBack failed, remote closed the connection", description = exc.msg
    return DialStatus.EDialBackError

  # TODO: failed because of client or server resources: EDialError

  trace "DialBack successful"
  return DialStatus.Ok

proc handleDialDataResponses(
    self: AutonatV2, conn: Connection
) {.async: (raises: [CancelledError, AutonatV2Error, LPStreamError]).} =
  var dataReceived: uint64 = 0

  while dataReceived < self.dialDataSize:
    let msg = AutonatV2Msg.decode(
      initProtoBuffer(await conn.readLp(AutonatV2DialDataResponseLpSize))
    ).valueOr:
      raise newException(AutonatV2Error, "Received malformed message")
    debug "Received message", msgType = $msg.msgType
    if msg.msgType != MsgType.DialDataResponse:
      raise
        newException(AutonatV2Error, "Expecting DialDataResponse, got " & $msg.msgType)
    let resp = msg.dialDataResp
    dataReceived += resp.data.len.uint64
    debug "received data",
      dataReceived = resp.data.len.uint64, totalDataReceived = dataReceived

proc amplificationAttackPrevention(
    self: AutonatV2, conn: Connection, addrIdx: AddrIdx
): Future[bool] {.async: (raises: [CancelledError, LPStreamError]).} =
  # send DialDataRequest
  await conn.writeLp(
    AutonatV2Msg(
      msgType: MsgType.DialDataRequest,
      dialDataReq: DialDataRequest(addrIdx: addrIdx, numBytes: self.dialDataSize),
    ).encode().buffer
  )

  # recieve DialDataResponses until we're satisfied
  try:
    if not await self.handleDialDataResponses(conn).withTimeout(self.dialTimeout):
      error "Amplification attack prevention timeout",
        timeout = self.amplificationAttackTimeout, peer = conn.peerId
      return false
  except AutonatV2Error as exc:
    error "Amplification attack prevention failed", description = exc.msg
    return false

  return true

proc canDial(self: AutonatV2, addrs: MultiAddress): bool =
  let (ipv4Support, ipv6Support) = self.switch.peerInfo.listenAddrs.ipSupport()
  addrs[0].withValue(addrIp):
    if IP4.match(addrIp) and not ipv4Support:
      return false
    if IP6.match(addrIp) and not ipv6Support:
      return false
    try:
      if isPrivate($addrIp):
        return false
    except ValueError:
      warn "Unable to parse IP address, skipping", addrs = $addrIp
      return false
  for t in self.switch.transports:
    if t.handles(addrs):
      return true
  return false

proc forceNewConnection(
    self: AutonatV2, pid: PeerId, addrs: seq[MultiAddress]
): Future[Opt[Connection]] {.async: (raises: [CancelledError]).} =
  ## Bypasses connManager to force a new connection to ``pid``
  ## instead of reusing a preexistent one
  try:
    let mux = await self.switch.dialer.dialAndUpgrade(Opt.some(pid), addrs)
    if mux.isNil():
      return Opt.none(Connection)
    return Opt.some(
      await self.switch.negotiateStream(
        await mux.newStream(), @[$AutonatV2Codec.DialBack]
      )
    )
  except CancelledError as exc:
    raise exc
  except CatchableError:
    return Opt.none(Connection)

proc chooseDialAddr(
    self: AutonatV2, pid: PeerId, addrs: seq[MultiAddress]
): Future[Opt[(Connection, AddrIdx)]] {.async: (raises: [CancelledError]).} =
  for i, ma in addrs:
    if self.canDial(ma):
      debug "Trying to dial", chosenAddrs = ma, addrIdx = i
      let conn = (await self.forceNewConnection(pid, @[ma])).valueOr:
        return Opt.none((Connection, AddrIdx))
      return Opt.some((conn, i.AddrIdx))
  return Opt.none((Connection, AddrIdx))

proc handleDialRequest(
    self: AutonatV2, conn: Connection, req: DialRequest
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let observedIPAddr = (await conn.findObservedIPAddr(req)).valueOr:
    error "Could not find observed IP address"
    return

  let (dialBackConn, addrIdx) = (await self.chooseDialAddr(conn.peerId, req.addrs)).valueOr:
    error "No dialable addresses found"
    await conn.sendDialResponse(ResponseStatus.EDialRefused)
    return
  defer:
    await dialBackConn.close()

  # if observed address for peer is not in address list to try
  # then we perform Amplification Attack Prevention
  if not ipAddrMatches(observedIPAddr, req.addrs):
    debug "Starting amplification attack prevention",
      observedIPAddr = observedIPAddr, testAddr = req.addrs[addrIdx]
    # send DialDataRequest and wait until dataReceived is enough
    if not await self.amplificationAttackPrevention(conn, addrIdx):
      return

  debug "Sending DialBack",
    nonce = req.nonce, addrIdx = addrIdx, addr = req.addrs[addrIdx]

  let dialStatus = await dialBackConn.dialBack(req.nonce)

  await conn.sendDialResponse(
    ResponseStatus.Ok, addrIdx = Opt.some(addrIdx), dialStatus = Opt.some(dialStatus)
  )

proc new*(
    T: typedesc[AutonatV2],
    switch: Switch,
    dialTimeout: Duration = DefaultDialTimeout,
    dialDataSize: uint64 = DefaultDialDataSize,
    amplificationAttackTimeout: Duration = DefaultAmplificationAttackDialTimeout,
): T =
  let autonatV2 = T(
    switch: switch,
    dialTimeout: dialTimeout,
    dialDataSize: dialDataSize,
    amplificationAttackTimeout: amplificationAttackTimeout,
  )
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let msg = AutonatV2Msg.decode(
        initProtoBuffer(await conn.readLp(AutonatV2MsgLpSize))
      ).valueOr:
        raise newException(AutonatV2Error, "Unable to decode AutonatV2Msg")
      debug "Received message", msgType = $msg.msgType
      if msg.msgType != MsgType.DialRequest:
        raise newException(AutonatV2Error, "Expecting DialRequest, got " & $msg.msgType)
      await autonatV2.handleDialRequest(conn, msg.dialReq)
    except LPStreamRemoteClosedError as exc:
      error "connection closed by peer", description = exc.msg, peer = conn.peerId
    except CatchableError as exc:
      debug "exception in handler", description = exc.msg, conn
    finally:
      await conn.close()

  autonatV2.handler = handleStream
  autonatV2.codec = $AutonatV2Codec.DialRequest
  autonatV2
