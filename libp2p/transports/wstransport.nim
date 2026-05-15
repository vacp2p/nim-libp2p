# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## WebSocket & WebSocket Secure transport implementation

{.push raises: [].}

import std/[sequtils]
import chronos, chronicles, results, metrics
import
  transport,
  ../autotls/service,
  ../errors,
  ../wire,
  ../multicodec,
  ../multistream,
  ../multiaddress,
  ../utility,
  ../crypto/rng,
  ../stream/connection,
  ../upgrademngrs/upgrade,
  websock/websock

logScope:
  topics = "libp2p wstransport"

export transport, websock, results

const
  DefaultHeadersTimeout = 3.seconds
  DefaultConcurrentAccepts = 200
  DefaultAcceptFailureBackoff = 100.millis
  DefaultAutotlsWaitTimeout = 3.seconds
  DefaultAutotlsRetries = 3

type
  WsStream = ref object of Connection
    session: WSSession
    when defined(libp2p_agents_metrics):
      tracked: bool

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
    localAddr: Opt[MultiAddress],
    timeout = 10.minutes,
): T {.raises: [].} =
  let stream = T(
    session: session,
    timeout: timeout,
    dir: dir,
    observedAddr: observedAddr,
    localAddr: localAddr,
  )

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

when defined(libp2p_agents_metrics):
  proc trackPeerIdentity(s: WsStream) =
    if not s.tracked and s.shortAgent.len > 0:
      libp2p_peers_identity.inc(labelValues = [s.shortAgent])
      s.tracked = true

  proc untrackPeerIdentity(s: WsStream) =
    if s.tracked:
      libp2p_peers_identity.dec(labelValues = [s.shortAgent])
      s.tracked = false

method readOnce*(
    s: WsStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  let res = mapExceptions(await s.session.recv(pbytes, nbytes))

  if res == 0 and s.session.readyState == ReadyState.Closed:
    raise newLPStreamEOFError()
  s.activity = true # reset activity flag
  libp2p_network_bytes.inc(res.int64, labelValues = ["in"])
  when defined(libp2p_agents_metrics):
    s.trackPeerIdentity()
    if s.tracked:
      libp2p_peers_traffic_read.inc(res.int64, labelValues = [s.shortAgent])
  return res

method write*(
    s: WsStream, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  mapExceptions(await s.session.send(msg, Opcode.Binary))
  s.activity = true # reset activity flag
  libp2p_network_bytes.inc(msg.len.int64, labelValues = ["out"])
  when defined(libp2p_agents_metrics):
    s.trackPeerIdentity()
    if s.tracked:
      libp2p_peers_traffic_write.inc(msg.len.int64, labelValues = [s.shortAgent])

method closeImpl*(s: WsStream): Future[void] {.async: (raises: []).} =
  try:
    await s.session.close()
  except CatchableError:
    discard
  when defined(libp2p_agents_metrics):
    s.untrackPeerIdentity()
  await procCall Connection(s).closeImpl()

method getWrapped*(s: WsStream): Connection =
  nil

type WsTransport* = ref object of Transport
  httpservers: seq[HttpServer]
  wsserver: WSServer
  connections: array[Direction, seq[WsStream]]
  connectionCleanupFuts: seq[Future[void]]
  acceptLoop: Future[void]
  handshakeFuts: seq[Future[void]]
  acceptResults: AsyncQueue[Connection]
  acceptSem: AsyncSemaphore

  tlsPrivateKey*: TLSPrivateKey
  tlsCertificate*: TLSCertificate
  autotls: Opt[AutotlsService]
  tlsFlags: set[TLSFlags]
  flags: set[ServerFlags]
  headersTimeout: Duration
  concurrentAccepts: int
  factories: seq[ExtFactory]
  rng: Rng

proc secure*(self: WsTransport): bool =
  not (isNil(self.tlsPrivateKey) or isNil(self.tlsCertificate))

proc notifyAcceptClosed(self: WsTransport) {.raises: [].} =
  if self.acceptResults.isNil:
    return

  try:
    self.acceptResults.addLastNoWait(nil)
  except AsyncQueueFullError:
    trace "Queue is full"

proc releaseAcceptSlot(self: WsTransport) {.raises: [].} =
  try:
    self.acceptSem.release()
  except AsyncSemaphoreError as e:
    trace "Error releasing WS accept semaphore", description = e.msg

proc closeHttpStream(stream: AsyncStream) {.async: (raises: []).} =
  try:
    await noCancel stream.closeWait()
  except CatchableError as e:
    trace "Error closing HTTP stream", description = e.msg

proc connHandler(
  self: WsTransport, stream: WSSession, secure: bool, dir: Direction
): Future[Connection] {.async: (raises: [CatchableError]).}

proc wsHandshakeWorker(
    self: WsTransport, server: HttpServer, stream: AsyncStream
) {.async: (raises: [CancelledError]).} =
  var accepted = false
  defer:
    self.releaseAcceptSlot()

  try:
    let conn = await (
      proc(): Future[Connection] {.async: (raises: [CatchableError]).} =
        let req = await readHttpRequest(stream, server.headersTimeout)
        let wstransp = await self.wsserver.handleRequest(req)
        return await self.connHandler(wstransp, server.secure, Direction.In)
    )()
      .wait(self.headersTimeout)

    await self.acceptResults.addLast(conn)
    accepted = true
  except WebSocketError as e:
    debug "Websocket Error", description = e.msg
  except HttpError as e:
    debug "Http Error", description = e.msg
  except AsyncStreamError as e:
    debug "AsyncStream Error", description = e.msg
  except AsyncTimeoutError as e:
    debug "Timed out", description = e.msg
  except CancelledError as e:
    if not accepted:
      await noCancel closeHttpStream(stream)
    raise e
  except CatchableError as e:
    debug "Unexpected error accepting websocket connection", description = e.msg

  if not accepted:
    await closeHttpStream(stream)

proc wsAcceptDispatcher(self: WsTransport) {.async: (raises: []).} =
  var acceptServers = self.httpservers
  var acceptFuts = acceptServers.mapIt(it.acceptStream())
  var notifyOnClose = false

  if acceptFuts.len == 0:
    self.notifyAcceptClosed()
    return

  try:
    while self.running:
      self.handshakeFuts.keepItIf(not it.finished)

      var acquired = false
      try:
        await self.acceptSem.acquire()
        acquired = true

        let finished =
          try:
            await one(acceptFuts)
          except ValueError:
            raiseAssert("accept futures should not be empty")

        let index = acceptFuts.find(finished)
        let server = acceptServers[index]

        if finished.completed():
          let stream = finished.read()
          acceptFuts[index] = server.acceptStream()
          self.handshakeFuts.add(self.wsHandshakeWorker(server, stream))
          acquired = false
        elif finished.failed():
          let exc = finished.error()
          if exc of TransportUseClosedError:
            debug "Server was closed", description = exc.msg
          elif exc of TransportTooManyError:
            debug "Too many files opened", description = exc.msg
          elif exc of TransportAbortedError:
            debug "Connection aborted", description = exc.msg
          elif exc of TransportOsError:
            debug "OS Error", description = exc.msg
          else:
            info "Unexpected error accepting websocket stream", description = exc.msg

          if acquired:
            self.releaseAcceptSlot()
            acquired = false

          if exc of TransportUseClosedError:
            acceptFuts.delete(index)
            acceptServers.delete(index)
            if acceptFuts.len == 0:
              self.running = false
              notifyOnClose = true
              break
          elif self.running:
            await sleepAsync(DefaultAcceptFailureBackoff)
            if self.running:
              acceptFuts[index] = server.acceptStream()
      except CancelledError:
        if acquired:
          self.releaseAcceptSlot()
        break
      except CatchableError as e:
        if acquired:
          self.releaseAcceptSlot()
        if self.running:
          info "Unexpected error in websocket accept dispatcher", description = e.msg
        else:
          break
  finally:
    for fut in acceptFuts:
      if not fut.finished:
        await noCancel fut.cancelAndWait()
      elif fut.completed():
        try:
          await closeHttpStream(fut.read())
        except CatchableError as e:
          trace "Error reading completed WS accept stream", description = e.msg

    if notifyOnClose:
      var toWait: seq[Future[void]]
      for fut in self.handshakeFuts:
        if not fut.finished:
          toWait.add(fut.cancelAndWait())

      if toWait.len > 0:
        try:
          await noCancel allFutures(toWait)
        except CatchableError as e:
          trace "Error stopping WS handshake workers", description = e.msg

      self.notifyAcceptClosed()

method start*(
    self: WsTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  ## listen on the transport
  ##
  trace "Starting WS transport"

  if self.running:
    warn "WS transport already running"
    return

  let addrsTa = self.toTransportAddress(addrs).valueOr:
    raise newException(TransportStartError, $error)

  when defined(libp2p_autotls_support):
    if not self.secure and self.autotls.isSome():
      self.autotls.withValue(autotls):
        if not await autotls.running.wait().withTimeout(DefaultAutotlsWaitTimeout):
          error "Unable to upgrade, autotls not running"
          await self.stop()
          return

        trace "Waiting for autotls certificate"
        try:
          let autotlsCert = await autotls.getCertWhenReady()
          self.tlsCertificate = autotlsCert.cert
          self.tlsPrivateKey = autotlsCert.privkey
        except AutoTLSError as e:
          raise newException(LPError, e.msg, e)
        except TLSStreamProtocolError as e:
          raise newException(LPError, e.msg, e)

  self.wsserver =
    WSServer.new(factories = self.factories, rng = bearSslDrbgRef(self.rng))

  var resolvedAddrs = addrs
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

    let httpserver =
      try:
        let address = addrsTa[i]
        if isWss:
          HttpServer.create(
            address = address,
            tlsPrivateKey = self.tlsPrivateKey,
            tlsCertificate = self.tlsCertificate,
            flags = self.flags,
            headersTimeout = self.headersTimeout,
          )
        else:
          HttpServer.create(address, headersTimeout = self.headersTimeout)
      except CatchableError as e:
        raise
          (ref WsTransportError)(msg: "error in WsTransport start: " & e.msg, parent: e)

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
    resolvedAddrs[i] =
      MultiAddress.init(httpserver.localAddress()).tryGet() & codec.tryGet()

  self.acceptSem = newAsyncSemaphore(self.concurrentAccepts)
  self.acceptResults = newAsyncQueue[Connection](self.concurrentAccepts)
  self.handshakeFuts = @[]

  await procCall Transport(self).start(resolvedAddrs)
  self.acceptLoop = self.wsAcceptDispatcher()

  trace "Listening on", addresses = self.addrs

method stop*(self: WsTransport) {.async: (raises: []).} =
  ## stop the transport
  ##

  self.running = false # mark stopped as soon as possible

  try:
    trace "Stopping WS transport"
    await procCall Transport(self).stop() # call base

    var toWait: seq[Future[void]]
    if not self.acceptLoop.isNil:
      toWait.add(self.acceptLoop.cancelAndWait())

    for fut in self.handshakeFuts:
      toWait.add(fut.cancelAndWait())

    for server in self.httpservers:
      server.stop()
      toWait.add(server.closeWait())

    await allFutures(toWait)

    # stop connections and wait for them to be closed
    discard await allFinished(
      self.connections[Direction.In].mapIt(it.close()) &
        self.connections[Direction.Out].mapIt(it.close())
    )
    self.connectionCleanupFuts.keepItIf(not it.finished)
    discard await allFinished(self.connectionCleanupFuts)

    self.httpservers = @[]
    self.handshakeFuts = @[]
    self.connectionCleanupFuts = @[]
    self.acceptLoop = nil
    trace "Transport stopped"
  except CatchableError as e:
    trace "Error shutting down ws transport", description = e.msg
  finally:
    self.notifyAcceptClosed()

proc connHandler(
    self: WsTransport, stream: WSSession, secure: bool, dir: Direction
): Future[Connection] {.async: (raises: [CatchableError]).} =
  ## Returning CatchableError is fine because we later handle different exceptions.

  let (observedAddr, localAddr) =
    try:
      let
        codec =
          if secure:
            MultiAddress.init("/wss")
          else:
            MultiAddress.init("/ws")
        remoteAddr = stream.stream.reader.tsource.remoteAddress
        localAddr = stream.stream.reader.tsource.localAddress

      (
        MultiAddress.init(remoteAddr).tryGet() & codec.tryGet(),
        MultiAddress.init(localAddr).tryGet() & codec.tryGet(),
      )
    except CatchableError as e:
      trace "Failed to create observedAddr or listenAddr", description = e.msg
      if not (isNil(stream) and stream.stream.reader.closed):
        safeClose(stream)
      raise e

  let conn = WsStream.new(stream, dir, Opt.some(observedAddr), Opt.some(localAddr))

  self.connections[dir].add(conn)
  proc onClose() {.async: (raises: []).} =
    await noCancel conn.session.stream.reader.join()
    self.connections[dir].keepItIf(it != conn)
    trace "Cleaned up client"

  self.connectionCleanupFuts.keepItIf(not it.finished)
  self.connectionCleanupFuts.add(onClose())

  return conn

method accept*(
    self: WsTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  trace "WsTransport accept"

  # wstransport can only start accepting connections after autotls is done
  # if autotls is not present, self.running is true after listener setup completes
  var retries = 0
  while not self.running and retries < DefaultAutotlsRetries:
    retries += 1
    await sleepAsync(DefaultAutotlsWaitTimeout)

  if not self.running:
    raise newTransportClosedError()

  let conn = await self.acceptResults.popFirst()
  if not conn.isNil:
    return conn

  raise newTransportClosedError()

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
      initAddress,
      "",
      secure = secure,
      hostName = hostname,
      flags = self.tlsFlags,
      rng = bearSslDrbgRef(self.rng),
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
    autotls: Opt[AutotlsService],
    rng: Rng,
    tlsFlags: set[TLSFlags] = {},
    flags: set[ServerFlags] = {},
    factories: openArray[ExtFactory] = [],
    headersTimeout = DefaultHeadersTimeout,
    concurrentAccepts = DefaultConcurrentAccepts,
): T {.raises: [].} =
  ## Creates a secure WebSocket transport
  doAssert concurrentAccepts > 0, "concurrentAccepts must be positive"

  doAssert not rng.isNil, "Rng is nil"

  let self = T(
    upgrader: upgrade,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    autotls: autotls,
    tlsFlags: tlsFlags,
    flags: flags,
    factories: @factories,
    rng: rng,
    headersTimeout: headersTimeout,
    concurrentAccepts: concurrentAccepts,
  )
  procCall Transport(self).initialize()
  self

proc new*(
    T: typedesc[WsTransport],
    upgrade: Upgrade,
    rng: Rng,
    flags: set[ServerFlags] = {},
    factories: openArray[ExtFactory] = [],
    headersTimeout = DefaultHeadersTimeout,
    concurrentAccepts = DefaultConcurrentAccepts,
): T {.raises: [].} =
  ## Creates a clear-text WebSocket transport

  T.new(
    upgrade = upgrade,
    tlsPrivateKey = nil,
    tlsCertificate = nil,
    autotls = Opt.none(AutotlsService),
    flags = flags,
    factories = @factories,
    rng = rng,
    headersTimeout = headersTimeout,
    concurrentAccepts = concurrentAccepts,
  )
