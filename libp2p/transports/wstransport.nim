# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## WebSocket & WebSocket Secure transport implementation

{.push raises: [].}

import std/[sequtils]
import stew/results
import chronos, chronicles
import
  transport,
  ../errors,
  ../wire,
  ../multicodec,
  ../multistream,
  ../connmanager,
  ../multiaddress,
  ../utility,
  ../stream/connection,
  ../upgrademngrs/upgrade,
  websock/websock

logScope:
  topics = "libp2p wstransport"

export transport, websock, results

const DefaultHeadersTimeout = 3.seconds

type WsStream = ref object of Connection
  session: WSSession

method initStream*(s: WsStream) =
  if s.objName.len == 0:
    s.objName = "WsStream"

  procCall Connection(s).initStream()

proc new*(
    T: type WsStream,
    session: WSSession,
    dir: Direction,
    observedAddr: Opt[MultiAddress],
    timeout = 10.minutes,
): T =
  let stream =
    T(session: session, timeout: timeout, dir: dir, observedAddr: observedAddr)

  stream.initStream()
  return stream

template mapExceptions(body: untyped) =
  try:
    body
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamLimitError:
    raise newLPStreamLimitError()
  except AsyncStreamUseClosedError:
    raise newLPStreamEOFError()
  except WSClosedError:
    raise newLPStreamEOFError()
  except WebSocketError:
    raise newLPStreamEOFError()
  except CatchableError:
    raise newLPStreamEOFError()

method readOnce*(
    s: WsStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  let res = mapExceptions(await s.session.recv(pbytes, nbytes))

  if res == 0 and s.session.readyState == ReadyState.Closed:
    raise newLPStreamEOFError()
  s.activity = true # reset activity flag
  return res

method write*(
    s: WsStream, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  mapExceptions(await s.session.send(msg, Opcode.Binary))
  s.activity = true # reset activity flag

method closeImpl*(s: WsStream): Future[void] {.async: (raises: []).} =
  try:
    await s.session.close()
  except CatchableError:
    discard
  await procCall Connection(s).closeImpl()

method getWrapped*(s: WsStream): Connection =
  nil

type WsTransport* = ref object of Transport
  httpservers: seq[HttpServer]
  wsserver: WSServer
  connections: array[Direction, seq[WsStream]]

  acceptFuts: seq[Future[HttpRequest]]

  tlsPrivateKey: TLSPrivateKey
  tlsCertificate: TLSCertificate
  tlsFlags: set[TLSFlags]
  flags: set[ServerFlags]
  handshakeTimeout: Duration
  factories: seq[ExtFactory]
  rng: ref HmacDrbgContext

proc secure*(self: WsTransport): bool =
  not (isNil(self.tlsPrivateKey) or isNil(self.tlsCertificate))

method start*(self: WsTransport, addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  if self.running:
    warn "WS transport already running"
    return

  await procCall Transport(self).start(addrs)
  trace "Starting WS transport"

  self.wsserver = WSServer.new(factories = self.factories, rng = self.rng)

  for i, ma in addrs:
    let isWss =
      if WSS.match(ma):
        if self.secure:
          true
        else:
          warn "Trying to listen on a WSS address without setting certificate!"
          false
      else:
        false

    let httpserver =
      if isWss:
        TlsHttpServer.create(
          address = ma.initTAddress().tryGet(),
          tlsPrivateKey = self.tlsPrivateKey,
          tlsCertificate = self.tlsCertificate,
          flags = self.flags,
          handshakeTimeout = self.handshakeTimeout,
        )
      else:
        HttpServer.create(
          ma.initTAddress().tryGet(), handshakeTimeout = self.handshakeTimeout
        )

    self.httpservers &= httpserver

    let codec =
      if isWss:
        if ma.contains(multiCodec("tls")) == MaResult[bool].ok(true):
          MultiAddress.init("/tls/ws")
        else:
          MultiAddress.init("/wss")
      else:
        MultiAddress.init("/ws")

    # always get the resolved address in case we're bound to 0.0.0.0:0
    self.addrs[i] =
      MultiAddress.init(httpserver.localAddress()).tryGet() & codec.tryGet()

  trace "Listening on", addresses = self.addrs

  self.running = true

method stop*(self: WsTransport) {.async.} =
  ## stop the transport
  ##

  self.running = false # mark stopped as soon as possible

  try:
    trace "Stopping WS transport"
    await procCall Transport(self).stop() # call base

    checkFutures(
      await allFinished(
        self.connections[Direction.In].mapIt(it.close()) &
          self.connections[Direction.Out].mapIt(it.close())
      )
    )

    var toWait: seq[Future[void]]
    for fut in self.acceptFuts:
      if not fut.finished:
        toWait.add(fut.cancelAndWait())
      elif fut.done:
        toWait.add(fut.read().stream.closeWait())

    for server in self.httpservers:
      server.stop()
      toWait.add(server.closeWait())

    await allFutures(toWait)

    self.httpservers = @[]
    trace "Transport stopped"
  except CatchableError as exc:
    trace "Error shutting down ws transport", exc = exc.msg

proc connHandler(
    self: WsTransport, stream: WSSession, secure: bool, dir: Direction
): Future[Connection] {.async.} =
  let observedAddr =
    try:
      let
        codec =
          if secure:
            MultiAddress.init("/wss")
          else:
            MultiAddress.init("/ws")
        remoteAddr = stream.stream.reader.tsource.remoteAddress

      MultiAddress.init(remoteAddr).tryGet() & codec.tryGet()
    except CatchableError as exc:
      trace "Failed to create observedAddr", exc = exc.msg
      if not (isNil(stream) and stream.stream.reader.closed):
        await stream.close()
      raise exc

  let conn = WsStream.new(stream, dir, Opt.some(observedAddr))

  self.connections[dir].add(conn)
  proc onClose() {.async.} =
    await conn.session.stream.reader.join()
    self.connections[dir].keepItIf(it != conn)
    trace "Cleaned up client"

  asyncSpawn onClose()
  return conn

method accept*(self: WsTransport): Future[Connection] {.async.} =
  ## accept a new WS connection
  ##

  if not self.running:
    raise newTransportClosedError()

  if self.acceptFuts.len <= 0:
    self.acceptFuts = self.httpservers.mapIt(it.accept())

  if self.acceptFuts.len <= 0:
    return

  let
    finished = await one(self.acceptFuts)
    index = self.acceptFuts.find(finished)

  self.acceptFuts[index] = self.httpservers[index].accept()

  try:
    let req = await finished

    try:
      let
        wstransp = await self.wsserver.handleRequest(req).wait(self.handshakeTimeout)
        isSecure = self.httpservers[index].secure

      return await self.connHandler(wstransp, isSecure, Direction.In)
    except CatchableError as exc:
      await req.stream.closeWait()
      raise exc
  except WebSocketError as exc:
    debug "Websocket Error", exc = exc.msg
  except HttpError as exc:
    debug "Http Error", exc = exc.msg
  except AsyncStreamError as exc:
    debug "AsyncStream Error", exc = exc.msg
  except TransportTooManyError as exc:
    debug "Too many files opened", exc = exc.msg
  except TransportAbortedError as exc:
    debug "Connection aborted", exc = exc.msg
  except AsyncTimeoutError as exc:
    debug "Timed out", exc = exc.msg
  except TransportUseClosedError as exc:
    debug "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CancelledError as exc:
    raise exc
  except TransportOsError as exc:
    debug "OS Error", exc = exc.msg
  except CatchableError as exc:
    info "Unexpected error accepting connection", exc = exc.msg
    raise exc

method dial*(
    self: WsTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address

  let
    secure = WSS.match(address)
    transp = await WebSocket.connect(
      address.initTAddress().tryGet(),
      "",
      secure = secure,
      hostName = hostname,
      flags = self.tlsFlags,
    )

  try:
    return await self.connHandler(transp, secure, Direction.Out)
  except CatchableError as exc:
    await transp.close()
    raise exc

method handles*(t: WsTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return WebSockets.match(address)

proc new*(
    T: typedesc[WsTransport],
    upgrade: Upgrade,
    tlsPrivateKey: TLSPrivateKey,
    tlsCertificate: TLSCertificate,
    tlsFlags: set[TLSFlags] = {},
    flags: set[ServerFlags] = {},
    factories: openArray[ExtFactory] = [],
    rng: ref HmacDrbgContext = nil,
    handshakeTimeout = DefaultHeadersTimeout,
): T {.public.} =
  ## Creates a secure WebSocket transport

  T(
    upgrader: upgrade,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    tlsFlags: tlsFlags,
    flags: flags,
    factories: @factories,
    rng: rng,
    handshakeTimeout: handshakeTimeout,
  )

proc new*(
    T: typedesc[WsTransport],
    upgrade: Upgrade,
    flags: set[ServerFlags] = {},
    factories: openArray[ExtFactory] = [],
    rng: ref HmacDrbgContext = nil,
    handshakeTimeout = DefaultHeadersTimeout,
): T {.public.} =
  ## Creates a clear-text WebSocket transport

  T.new(
    upgrade = upgrade,
    tlsPrivateKey = nil,
    tlsCertificate = nil,
    flags = flags,
    factories = @factories,
    rng = rng,
    handshakeTimeout = handshakeTimeout,
  )
