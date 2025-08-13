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
import results
import chronos, chronicles
import
  transport,
  ../autotls/service,
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

const
  DefaultHeadersTimeout = 3.seconds
  DefaultAutotlsWaitTimeout = 3.seconds
  DefaultAutotlsRetries = 3

type
  WsStream = ref object of Connection
    session: WSSession

  WsTransportError* = object of transport.TransportError

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

template mapExceptions(body: untyped): untyped =
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

  tlsPrivateKey*: TLSPrivateKey
  tlsCertificate*: TLSCertificate
  autotls: AutotlsService
  tlsFlags: set[TLSFlags]
  flags: set[ServerFlags]
  handshakeTimeout: Duration
  factories: seq[ExtFactory]
  rng: ref HmacDrbgContext

proc secure*(self: WsTransport): bool =
  not (isNil(self.tlsPrivateKey) or isNil(self.tlsCertificate))

method start*(
    self: WsTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  ## listen on the transport
  ##

  if self.running:
    warn "WS transport already running"
    return

  when defined(libp2p_autotls_support):
    if not self.secure and not self.autotls.isNil():
      if not await self.autotls.running.wait().withTimeout(DefaultAutotlsWaitTimeout):
        error "Unable to upgrade, autotls not running"
        await self.stop()
        return

      trace "Waiting for autotls certificate"
      try:
        let autotlsCert = await self.autotls.getCertWhenReady()
        self.tlsCertificate = autotlsCert.cert
        self.tlsPrivateKey = autotlsCert.privkey
      except AutoTLSError as exc:
        raise newException(LPError, exc.msg, exc)
      except TLSStreamProtocolError as exc:
        raise newException(LPError, exc.msg, exc)

  trace "Starting WS transport"
  await procCall Transport(self).start(addrs)

  self.wsserver = WSServer.new(factories = self.factories, rng = self.rng)

  for i, ma in addrs:
    let isWss =
      if WSS.match(ma):
        if self.secure:
          true
        else:
          warn "Trying to listen on a WSS address without setting certificate or autotls!"
          false
      else:
        false

    let address = ma.initTAddress().tryGet()

    let httpserver =
      try:
        if isWss:
          TlsHttpServer.create(
            address = address,
            tlsPrivateKey = self.tlsPrivateKey,
            tlsCertificate = self.tlsCertificate,
            flags = self.flags,
            handshakeTimeout = self.handshakeTimeout,
          )
        else:
          HttpServer.create(address, handshakeTimeout = self.handshakeTimeout)
      except CatchableError as exc:
        raise (ref WsTransportError)(
          msg: "error in WsTransport start: " & exc.msg, parent: exc
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

method stop*(self: WsTransport) {.async: (raises: []).} =
  ## stop the transport
  ##

  self.running = false # mark stopped as soon as possible

  try:
    trace "Stopping WS transport"
    await procCall Transport(self).stop() # call base

    discard await allFinished(
      self.connections[Direction.In].mapIt(it.close()) &
        self.connections[Direction.Out].mapIt(it.close())
    )

    var toWait: seq[Future[void]]
    for fut in self.acceptFuts:
      if not fut.finished:
        toWait.add(fut.cancelAndWait())
      elif fut.completed:
        toWait.add(fut.read().stream.closeWait())

    for server in self.httpservers:
      server.stop()
      toWait.add(server.closeWait())

    await allFutures(toWait)

    self.httpservers = @[]
    trace "Transport stopped"
  except CatchableError as exc:
    trace "Error shutting down ws transport", description = exc.msg

proc connHandler(
    self: WsTransport, stream: WSSession, secure: bool, dir: Direction
): Future[Connection] {.async: (raises: [CatchableError]).} =
  ## Returning CatchableError is fine because we later handle different exceptions.
  ## 

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
      trace "Failed to create observedAddr", description = exc.msg
      if not (isNil(stream) and stream.stream.reader.closed):
        safeClose(stream)
      raise exc

  let conn = WsStream.new(stream, dir, Opt.some(observedAddr))

  self.connections[dir].add(conn)
  proc onClose() {.async: (raises: []).} =
    await noCancel conn.session.stream.reader.join()
    self.connections[dir].keepItIf(it != conn)
    trace "Cleaned up client"

  asyncSpawn onClose()
  return conn

method accept*(
    self: WsTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  trace "WsTransport accept"

  # wstransport can only start accepting connections after autotls is done
  # if autotls is not present, self.running will be true right after start is called
  var retries = 0
  while not self.running and retries < DefaultAutotlsRetries:
    retries += 1
    await sleepAsync(DefaultAutotlsWaitTimeout)

  if not self.running:
    raise newTransportClosedError()

  if self.acceptFuts.len <= 0:
    self.acceptFuts = self.httpservers.mapIt(it.accept())

  if self.acceptFuts.len <= 0:
    return

  let finished =
    try:
      await one(self.acceptFuts)
    except ValueError:
      raiseAssert("already checked with if")
    except CancelledError as e:
      raise e

  let index = self.acceptFuts.find(finished)
  self.acceptFuts[index] = self.httpservers[index].accept()

  try:
    let req = await finished

    try:
      let wstransp = await self.wsserver.handleRequest(req).wait(self.handshakeTimeout)
      let isSecure = self.httpservers[index].secure

      return await self.connHandler(wstransp, isSecure, Direction.In)
    except CatchableError as exc:
      await noCancel req.stream.closeWait()
      raise exc
  except WebSocketError as exc:
    debug "Websocket Error", description = exc.msg
  except HttpError as exc:
    debug "Http Error", description = exc.msg
  except AsyncStreamError as exc:
    debug "AsyncStream Error", description = exc.msg
  except TransportTooManyError as exc:
    debug "Too many files opened", description = exc.msg
  except TransportAbortedError as exc:
    debug "Connection aborted", description = exc.msg
  except AsyncTimeoutError as exc:
    debug "Timed out", description = exc.msg
  except TransportUseClosedError as exc:
    debug "Server was closed", description = exc.msg
    raise newTransportClosedError(exc)
  except CancelledError as exc:
    raise exc
  except TransportOsError as exc:
    debug "OS Error", description = exc.msg
  except CatchableError as exc:
    info "Unexpected error accepting connection", description = exc.msg
    raise newException(
      transport.TransportError, "Error in WsTransport accept: " & exc.msg, exc
    )

method dial*(
    self: WsTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address
  var transp: websock.WSSession

  try:
    let secure = WSS.match(address)
    let initAddress = address.initTAddress().tryGet()
    debug "creating websocket",
      address = initAddress, secure = secure, hostName = hostname
    transp = await WebSocket.connect(
      initAddress, "", secure = secure, hostName = hostname, flags = self.tlsFlags
    )
    return await self.connHandler(transp, secure, Direction.Out)
  except CancelledError as e:
    safeClose(transp)
    raise e
  except CatchableError as e:
    safeClose(transp)
    raise newException(
      transport.TransportDialError, "error in WsTransport dial: " & e.msg, e
    )

method handles*(t: WsTransport, address: MultiAddress): bool {.gcsafe, raises: [].} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return WebSockets.match(address)

proc new*(
    T: typedesc[WsTransport],
    upgrade: Upgrade,
    tlsPrivateKey: TLSPrivateKey,
    tlsCertificate: TLSCertificate,
    autotls: AutotlsService,
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
    autotls: autotls,
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
    autotls = nil,
    flags = flags,
    factories = @factories,
    rng = rng,
    handshakeTimeout = handshakeTimeout,
  )
