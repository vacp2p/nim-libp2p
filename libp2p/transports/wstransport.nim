## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[sequtils]
import chronos, chronicles
import transport,
       ../errors,
       ../wire,
       ../multicodec,
       ../multistream,
       ../connmanager,
       ../multiaddress,
       ../stream/connection,
       ../upgrademngrs/upgrade,
       websock/websock

logScope:
  topics = "libp2p wstransport"

export transport, websock

const
  WsTransportTrackerName* = "libp2p.wstransport"

type
  WsStream = ref object of Connection
    session: WSSession

proc new*(T: type WsStream,
           session: WSSession,
           dir: Direction,
           timeout = 10.minutes,
           observedAddr: MultiAddress = MultiAddress()): T =

  let stream = T(
    session: session,
    timeout: timeout,
    dir: dir,
    observedAddr: observedAddr)

  stream.initStream()
  return stream

template mapExceptions(body: untyped) =
  try:
    body
  except AsyncStreamIncompleteError:
    raise newLPStreamEOFError()
  except AsyncStreamUseClosedError:
    raise newLPStreamEOFError()
  except WSClosedError:
    raise newLPStreamEOFError()
  except AsyncStreamLimitError:
    raise newLPStreamLimitError()

method readOnce*(
  s: WsStream,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =
  let res = mapExceptions(await s.session.recv(pbytes, nbytes))

  if res == 0 and s.session.readyState == ReadyState.Closed:
    raise newLPStreamEOFError()
  return res

method write*(
  s: WsStream,
  msg: seq[byte]): Future[void] {.async.} =
  mapExceptions(await s.session.send(msg, Opcode.Binary))

method closeImpl*(s: WsStream): Future[void] {.async.} =
  await s.session.close()
  await procCall Connection(s).closeImpl()

type
  WsTransport* = ref object of Transport
    httpservers: seq[HttpServer]
    wsserver: WSServer
    connections: array[Direction, seq[WsStream]]

    acceptFuts: seq[Future[HttpRequest]]

    tlsPrivateKey: TLSPrivateKey
    tlsCertificate: TLSCertificate
    tlsFlags: set[TLSFlags]
    flags: set[ServerFlags]
    factories: seq[ExtFactory]
    rng: Rng

proc secure*(self: WsTransport): bool =
  not (isNil(self.tlsPrivateKey) or isNil(self.tlsCertificate))

method start*(
  self: WsTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  if self.running:
    warn "WS transport already running"
    return

  await procCall Transport(self).start(addrs)
  trace "Starting WS transport"

  self.wsserver = WSServer.new(
    factories = self.factories,
    rng = self.rng)

  
  for i, ma in addrs:
    let isWss =
      if WSS.match(ma):
        if self.secure: true
        else:
          warn "Trying to listen on a WSS address without setting the certificate!"
          false
      else: false

    let httpserver =
      if isWss:
        TlsHttpServer.create(
          address = ma.initTAddress().tryGet(),
          tlsPrivateKey = self.tlsPrivateKey,
          tlsCertificate = self.tlsCertificate,
          flags = self.flags)
      else:
        HttpServer.create(ma.initTAddress().tryGet())

    self.httpservers &= httpserver

    let codec = if isWss:
        MultiAddress.init("/wss")
      else:
        MultiAddress.init("/ws")

    # always get the resolved address in case we're bound to 0.0.0.0:0
    self.addrs[i] = MultiAddress.init(
      httpserver.localAddress()).tryGet() & codec.tryGet()

  trace "Listening on", addresses = self.addrs

  self.running = true

method stop*(self: WsTransport) {.async, gcsafe.} =
  ## stop the transport
  ##

  self.running = false # mark stopped as soon as possible

  try:
    trace "Stopping WS transport"
    await procCall Transport(self).stop() # call base

    checkFutures(
      await allFinished(
        self.connections[Direction.In].mapIt(it.close()) &
        self.connections[Direction.Out].mapIt(it.close())))

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

proc connHandler(self: WsTransport,
                 stream: WSSession,
                 secure: bool,
                 dir: Direction): Future[Connection] {.async.} =
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
      if not(isNil(stream) and stream.stream.reader.closed):
        await stream.close()
      raise exc

  let conn = WsStream.new(stream, dir)
  conn.observedAddr = observedAddr

  self.connections[dir].add(conn)
  proc onClose() {.async.} =
    await conn.session.stream.reader.join()
    self.connections[dir].keepItIf(it != conn)
    trace "Cleaned up client"
  asyncSpawn onClose()
  return conn

method accept*(self: WsTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new WS connection
  ##

  if not self.running:
    raise newTransportClosedError()

  try:
    if self.acceptFuts.len <= 0:
      self.acceptFuts = self.httpservers.mapIt(it.accept())

    if self.acceptFuts.len <= 0:
      return

    let
      finished = await one(self.acceptFuts)
      index = self.acceptFuts.find(finished)

    self.acceptFuts[index] = self.httpservers[index].accept()

    let req = await finished

    try:
      let
        wstransp = await self.wsserver.handleRequest(req)
        isSecure = self.httpservers[index].secure

      return await self.connHandler(wstransp, isSecure, Direction.In)
    except CatchableError as exc:
      await req.stream.closeWait()
      raise exc
  except TransportOsError as exc:
    debug "OS Error", exc = exc.msg
  except WebSocketError as exc:
    debug "Websocket Error", exc = exc.msg
  except AsyncStreamError as exc:
    debug "AsyncStream Error", exc = exc.msg
  except TransportTooManyError as exc:
    debug "Too many files opened", exc = exc.msg
  except TransportUseClosedError as exc:
    debug "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CancelledError as exc:
    # bubble up silently
    raise exc
  except CatchableError as exc:
    warn "Unexpected error accepting connection", exc = exc.msg
    raise exc

method dial*(
  self: WsTransport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
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
      flags = self.tlsFlags)

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
  rng: Rng = nil): T =

  T(
    upgrader: upgrade,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    tlsFlags: tlsFlags,
    flags: flags,
    factories: @factories,
    rng: rng)

proc new*(
  T: typedesc[WsTransport],
  upgrade: Upgrade,
  flags: set[ServerFlags] = {},
  factories: openArray[ExtFactory] = [],
  rng: Rng = nil): T =

  T.new(
    upgrade = upgrade,
    tlsPrivateKey = nil,
    tlsCertificate = nil,
    flags = flags,
    factories = @factories,
    rng = rng)
