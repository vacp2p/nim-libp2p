# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

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
    utils/ipaddr,
  ],
  ../../protocol,
  ./types

logScope:
  topics = "libp2p autonat v2 server"

type AutonatV2Config* = object
  dialTimeout: Duration
  dialDataSize: uint64
  amplificationAttackTimeout: Duration
  allowPrivateAddresses: bool

type AutonatV2* = ref object of LPProtocol
  switch*: Switch
  config: AutonatV2Config

proc new*(
    T: typedesc[AutonatV2Config],
    dialTimeout: Duration = DefaultDialTimeout,
    dialDataSize: uint64 = DefaultDialDataSize,
    amplificationAttackTimeout: Duration = DefaultAmplificationAttackDialTimeout,
    allowPrivateAddresses: bool = false,
): T =
  T(
    dialTimeout: dialTimeout,
    dialDataSize: dialDataSize,
    amplificationAttackTimeout: amplificationAttackTimeout,
    allowPrivateAddresses: allowPrivateAddresses,
  )

proc sendDialResponse(
    stream: Stream,
    status: ResponseStatus,
    addrIdx: Opt[AddrIdx] = Opt.none(AddrIdx),
    dialStatus: Opt[DialStatus] = Opt.none(DialStatus),
) {.async: (raises: [CancelledError, LPStreamError]).} =
  await stream.writeLp(
    AutonatV2Msg(
      oneof: AutonatV2MsgOneof(
        kind: MsgKind.DialResponse,
        dialResponse:
          DialResponse(status: status, addrIdx: addrIdx, dialStatus: dialStatus),
      )
    ).encode()
  )

proc findObservedIPAddr*(
    stream: Stream, req: DialRequest
): Future[Opt[MultiAddress]] {.async: (raises: [CancelledError, LPStreamError]).} =
  let observedAddr = stream.observedAddr.valueOr:
    await stream.sendDialResponse(ResponseStatus.EInternalError)
    return Opt.none(MultiAddress)

  let isRelayed = observedAddr.contains(multiCodec("p2p-circuit")).valueOr:
    error "Invalid observed address"
    await stream.sendDialResponse(ResponseStatus.EDialRefused)
    return Opt.none(MultiAddress)

  if isRelayed:
    error "Invalid observed address: relayed address"
    await stream.sendDialResponse(ResponseStatus.EDialRefused)
    return Opt.none(MultiAddress)

  let hostIp = observedAddr[0].valueOr:
    error "Invalid observed address"
    await stream.sendDialResponse(ResponseStatus.EInternalError)
    return Opt.none(MultiAddress)

  return Opt.some(hostIp)

proc dialBack(
    stream: Stream, nonce: Nonce
): Future[DialStatus] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  try:
    # send dial back
    await stream.writeLp(DialBack(nonce: nonce).encode())

    # receive DialBackResponse
    discard DialBackResponse.decode(await stream.readLp(AutonatV2MsgLpSize)).valueOr:
      trace "DialBack failed, could not decode DialBackResponse", error = error
      return DialStatus.EDialBackError
  except LPStreamRemoteClosedError as exc:
    # failed because of nonce error (remote reset the stream): EDialBackError
    debug "DialBack failed, remote closed the connection", description = exc.msg
    return DialStatus.EDialBackError

  # TODO: failed because of client or server resources: EDialError

  trace "DialBack successful"
  return DialStatus.Ok

proc handleDialDataResponses(
    self: AutonatV2, stream: Stream
) {.async: (raises: [CancelledError, AutonatV2Error, LPStreamError]).} =
  var dataReceived: uint64 = 0

  while dataReceived < self.config.dialDataSize:
    let msg = AutonatV2Msg.decode(await stream.readLp(DialDataResponseLpSize)).valueOr:
      raise newException(AutonatV2Error, error)
    debug "Received message"

    if msg.oneof.kind != MsgKind.DialDataResponse:
      raise newException(
        AutonatV2Error, "Expecting DialDataResponse, got " & $msg.oneof.kind
      )

    let resp = msg.oneof.dialDataResponse
    dataReceived += resp.data.len.uint64
    debug "received data",
      dataReceived = resp.data.len.uint64, totalDataReceived = dataReceived

proc amplificationAttackPrevention(
    self: AutonatV2, stream: Stream, addrIdx: AddrIdx
): Future[bool] {.async: (raises: [CancelledError, LPStreamError]).} =
  # send DialDataRequest
  await stream.writeLp(
    AutonatV2Msg(
      oneof: AutonatV2MsgOneof(
        kind: MsgKind.DialDataRequest,
        dialDataRequest:
          DialDataRequest(addrIdx: addrIdx, numBytes: self.config.dialDataSize),
      )
    ).encode()
  )

  # recieve DialDataResponses until we're satisfied
  try:
    await self.handleDialDataResponses(stream)
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
      if not self.config.allowPrivateAddresses and isPrivate($addrIp):
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
): Future[Opt[(Muxer, Stream)]] {.async: (raises: [CancelledError]).} =
  ## Bypasses connManager to force a new connection to ``pid``
  ## instead of reusing a preexistent one
  try:
    let mux = await self.switch.dialer.dialAndUpgrade(Opt.some(pid), addrs)
    if mux.isNil():
      return Opt.none((Muxer, Stream))
    return Opt.some(
      (
        mux,
        await self.switch.dialer.negotiateStream(
          await mux.newStream(), @[$AutonatV2Codec.DialBack]
        ),
      )
    )
  except CancelledError as exc:
    raise exc
  except CatchableError:
    return Opt.none((Muxer, Stream))

proc chooseDialAddr(
    self: AutonatV2, pid: PeerId, addrs: seq[MultiAddress]
): Future[(Opt[(Muxer, Stream)], Opt[AddrIdx])] {.async: (raises: [CancelledError]).} =
  for i, ma in addrs:
    if self.canDial(ma):
      debug "Trying to dial", chosenAddrs = ma, addrIdx = i
      let (mux, stream) =
        try:
          (await (self.forceNewConnection(pid, @[ma]).wait(self.config.dialTimeout))).valueOr:
            # canDial is true, which means the dial was attempted but failed.
            # Opt.some(i.AddrIdx) is returned so the response is EDialError, which
            # triggers NotReachable, and not EDialRefused, which triggers Unknown
            # and would never be updated.
            return (Opt.none((Muxer, Stream)), Opt.some(i.AddrIdx))
        except AsyncTimeoutError:
          trace "Dial timed out"
          return (Opt.none((Muxer, Stream)), Opt.some(i.AddrIdx))
      return (Opt.some((mux, stream)), Opt.some(i.AddrIdx))
  return (Opt.none((Muxer, Stream)), Opt.none(AddrIdx))

proc handleDialRequest(
    self: AutonatV2, stream: Stream, req: DialRequest
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let observedIPAddr = (await stream.findObservedIPAddr(req)).valueOr:
    trace "Could not find observed IP address"
    await stream.sendDialResponse(ResponseStatus.ERequestRejected)
    return

  let (dialBackConnOpt, addrIdxOpt) =
    await self.chooseDialAddr(stream.peerId, req.addrs)
  let addrIdx = addrIdxOpt.valueOr:
    trace "No dialable addresses found"
    await stream.sendDialResponse(ResponseStatus.EDialRefused)
    return
  let (dialBackMux, dialBackConn) = dialBackConnOpt.valueOr:
    trace "Dial failed"
    await stream.sendDialResponse(
      ResponseStatus.Ok,
      addrIdx = Opt.some(addrIdx),
      dialStatus = Opt.some(DialStatus.EDialError),
    )
    return
  defer:
    await dialBackConn.close()
    await dialBackMux.close()

  # if observed address for peer is not in address list to try
  # then we perform Amplification Attack Prevention
  if not ipAddrMatches(observedIPAddr, req.addrs):
    debug "Starting amplification attack prevention",
      observedIPAddr = observedIPAddr, testAddr = req.addrs[addrIdx]
    # send DialDataRequest and wait until dataReceived is enough
    if not await self.amplificationAttackPrevention(stream, addrIdx).withTimeout(
      self.config.amplificationAttackTimeout
    ):
      debug "Amplification attack prevention timeout",
        timeout = self.config.amplificationAttackTimeout, peer = stream.peerId
      await stream.sendDialResponse(ResponseStatus.EDialRefused)
      return

  debug "Sending DialBack",
    nonce = req.nonce, addrIdx = addrIdx, addr = req.addrs[addrIdx]

  try:
    let dialStatus =
      await dialBackConn.dialBack(req.nonce).wait(self.config.dialTimeout)
    await stream.sendDialResponse(
      ResponseStatus.Ok, addrIdx = Opt.some(addrIdx), dialStatus = Opt.some(dialStatus)
    )
  except DialFailedError as exc:
    debug "DialBack failed", description = exc.msg
    await stream.sendDialResponse(
      ResponseStatus.Ok,
      addrIdx = Opt.some(addrIdx),
      dialStatus = Opt.some(DialStatus.EDialBackError),
    )
  except AsyncTimeoutError:
    debug "DialBack timeout", timeout = self.config.dialTimeout
    await stream.sendDialResponse(
      ResponseStatus.Ok,
      addrIdx = Opt.some(addrIdx),
      dialStatus = Opt.some(DialStatus.EDialBackError),
    )

proc new*(
    Self: typedesc[AutonatV2],
    switch: Switch,
    config: AutonatV2Config = AutonatV2Config.new(),
): Self =
  # Self instead of T to avoid clashing with withValue[T]'s type param under --lineDir:on
  let autonatV2 = Self(switch: switch, config: config)
  proc handleStream(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await stream.close()

    let msg =
      try:
        AutonatV2Msg.decode(await stream.readLp(AutonatV2MsgLpSize)).valueOr:
          trace "Unable to decode AutonatV2Msg", error = error
          return
      except LPStreamError as exc:
        debug "Could not receive AutonatV2Msg", description = exc.msg
        return

    debug "Received message", kind = $msg.oneof.kind
    if msg.oneof.kind != MsgKind.DialRequest:
      debug "Expecting DialRequest", receivedMsgType = msg.oneof.kind

    try:
      await autonatV2.handleDialRequest(stream, msg.oneof.dialRequest)
    except CancelledError as exc:
      raise exc
    except LPStreamRemoteClosedError as exc:
      debug "Stream closed by peer", description = exc.msg, peer = stream.peerId
    except LPStreamError as exc:
      debug "Stream Error", description = exc.msg

  autonatV2.handler = handleStream
  autonatV2.codec = $AutonatV2Codec.DialRequest
  autonatV2
