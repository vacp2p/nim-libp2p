import std/sequtils
import chronos
import chronicles
import metrics
import quic
import results
import ../multiaddress
import ../multicodec
import ../stream/connection
import ../wire
import ../muxers/muxer
import ../upgrademngrs/upgrade
import ./transport
import tls/certificate

export multiaddress
export multicodec
export connection
export transport

logScope:
  topics = "libp2p quictransport"

type
  P2PConnection = connection.Connection
  QuicConnection = quic.Connection
  QuicTransportError* = object of transport.TransportError
  QuicTransportDialError* = object of transport.TransportDialError
  QuicTransportAcceptStopped* = object of QuicTransportError

const alpn = "libp2p"

# Stream
type QuicStream* = ref object of P2PConnection
  stream: Stream
  cached: seq[byte]

proc new(
    _: type QuicStream,
    stream: Stream,
    oaddr: Opt[MultiAddress],
    laddr: Opt[MultiAddress],
    peerId: PeerId,
): QuicStream =
  let quicstream =
    QuicStream(stream: stream, observedAddr: oaddr, localAddr: laddr, peerId: peerId)
  procCall P2PConnection(quicstream).initStream()
  quicstream

method getWrapped*(self: QuicStream): P2PConnection =
  self

method readOnce*(
    stream: QuicStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if stream.cached.len == 0:
    try:
      stream.cached = await stream.stream.read()
      if stream.cached.len == 0:
        raise newLPStreamEOFError()
    except CancelledError as exc:
      raise exc
    except LPStreamEOFError as exc:
      raise exc
    except CatchableError as exc:
      raise (ref LPStreamError)(msg: "error in readOnce: " & exc.msg, parent: exc)

  let toRead = min(nbytes, stream.cached.len)
  copyMem(pbytes, addr stream.cached[0], toRead)
  stream.cached = stream.cached[toRead ..^ 1]
  libp2p_network_bytes.inc(toRead.int64, labelValues = ["in"])
  return toRead

{.push warning[LockLevel]: off.}
method write*(
    stream: QuicStream, bytes: seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  try:
    await stream.stream.write(bytes)
    libp2p_network_bytes.inc(bytes.len.int64, labelValues = ["out"])
  except QuicError:
    raise newLPStreamEOFError()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise
      (ref LPStreamError)(msg: "error in quic stream write: " & exc.msg, parent: exc)

{.pop.}

method closeWrite*(stream: QuicStream) {.async: (raises: []).} =
  ## Close the write side of the QUIC stream
  try:
    await stream.stream.closeWrite()
  except CatchableError as exc:
    discard

method closeImpl*(stream: QuicStream) {.async: (raises: []).} =
  try:
    await stream.stream.close()
  except CatchableError as exc:
    discard
  await procCall P2PConnection(stream).closeImpl()

# Session
type QuicSession* = ref object of P2PConnection
  connection: QuicConnection
  streams: seq[QuicStream]

method close*(session: QuicSession) {.async: (raises: []).} =
  for s in session.streams:
    await s.close()
  safeClose(session.connection)
  await procCall P2PConnection(session).close()

proc getStream*(
    session: QuicSession, direction = Direction.In
): Future[QuicStream] {.async: (raises: [QuicTransportError]).} =
  try:
    var stream: Stream
    case direction
    of Direction.In:
      stream = await session.connection.incomingStream()
    of Direction.Out:
      stream = await session.connection.openStream()
      await stream.write(@[]) # QUIC streams do not exist until data is sent

    let qs =
      QuicStream.new(stream, session.observedAddr, session.localAddr, session.peerId)
    when defined(libp2p_agents_metrics):
      qs.shortAgent = session.shortAgent

    session.streams.add(qs)
    return qs
  except CatchableError as exc:
    # TODO: incomingStream is using {.async.} with no raises
    raise (ref QuicTransportError)(msg: "error in getStream: " & exc.msg, parent: exc)

method getWrapped*(self: QuicSession): P2PConnection =
  self

# Muxer
type QuicMuxer = ref object of Muxer
  quicSession: QuicSession
  handleFut: Future[void]

when defined(libp2p_agents_metrics):
  method setShortAgent*(m: QuicMuxer, shortAgent: string) =
    m.quicSession.shortAgent = shortAgent
    for s in m.quicSession.streams:
      s.shortAgent = shortAgent
    m.connection.shortAgent = shortAgent

method newStream*(
    m: QuicMuxer, name: string = "", lazy: bool = false
): Future[P2PConnection] {.
    async: (raises: [CancelledError, LPStreamError, MuxerError])
.} =
  try:
    return await m.quicSession.getStream(Direction.Out)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(MuxerError, "error in newStream: " & exc.msg, exc)

proc handleStream(m: QuicMuxer, chann: QuicStream) {.async: (raises: []).} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in quic stream handler", msg = exc.msg
    await chann.close()

method handle*(m: QuicMuxer): Future[void] {.async: (raises: []).} =
  try:
    while not m.quicSession.atEof:
      let incomingStream = await m.quicSession.getStream(Direction.In)
      asyncSpawn m.handleStream(incomingStream)
  except CatchableError as exc:
    trace "Exception in quic handler", msg = exc.msg

method close*(m: QuicMuxer) {.async: (raises: []).} =
  try:
    await m.quicSession.close()
    m.handleFut.cancelSoon()
  except CatchableError as exc:
    discard

# Transport
type QuicUpgrade = ref object of Upgrade

type CertGenerator =
  proc(kp: KeyPair): CertificateX509 {.gcsafe, raises: [TLSCertificateError].}

type QuicTransport* = ref object of Transport
  listener: Listener
  client: Opt[QuicClient]
  privateKey: PrivateKey
  connections: seq[P2PConnection]
  rng: ref HmacDrbgContext
  certGenerator: CertGenerator

proc makeCertificateVerifier(): CertificateVerifier =
  proc certificateVerifier(serverName: string, certificatesDer: seq[seq[byte]]): bool =
    if certificatesDer.len != 1:
      trace "CertificateVerifier: expected one certificate in the chain",
        cert_count = certificatesDer.len
      return false

    let cert =
      try:
        parse(certificatesDer[0])
      except CertificateParsingError as e:
        trace "CertificateVerifier: failed to parse certificate", msg = e.msg
        return false

    return cert.verify()

  return CustomCertificateVerifier.init(certificateVerifier)

proc defaultCertGenerator(
    kp: KeyPair
): CertificateX509 {.gcsafe, raises: [TLSCertificateError].} =
  return generateX509(kp, encodingFormat = EncodingFormat.PEM)

proc new*(_: type QuicTransport, u: Upgrade, privateKey: PrivateKey): QuicTransport =
  return QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms),
    privateKey: privateKey,
    certGenerator: defaultCertGenerator,
  )

proc new*(
    _: type QuicTransport,
    u: Upgrade,
    privateKey: PrivateKey,
    certGenerator: CertGenerator,
): QuicTransport =
  return QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms),
    privateKey: privateKey,
    certGenerator: certGenerator,
  )

method handles*(transport: QuicTransport, address: MultiAddress): bool {.raises: [].} =
  if not procCall Transport(transport).handles(address):
    return false
  QUIC_V1.match(address)

proc makeConfig(self: QuicTransport): TLSConfig =
  let pubkey = self.privateKey.getPublicKey().valueOr:
    doAssert false, "could not obtain public key"
    return

  let cert = self.certGenerator(KeyPair(seckey: self.privateKey, pubkey: pubkey))
  let tlsConfig = TLSConfig.init(
    cert.certificate, cert.privateKey, @[alpn], Opt.some(makeCertificateVerifier())
  )
  return tlsConfig

proc getRng(self: QuicTransport): ref HmacDrbgContext =
  if self.rng.isNil:
    self.rng = newRng()

  return self.rng

method start*(
    self: QuicTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  doAssert self.listener.isNil, "start() already called"
  # TODO(#1663): handle multiple addr

  try:
    self.listener = QuicServer.init(self.makeConfig(), rng = self.getRng()).listen(
        initTAddress(addrs[0]).tryGet
      )
    await procCall Transport(self).start(addrs)
    self.addrs[0] =
      MultiAddress.init(self.listener.localAddress(), IPPROTO_UDP).tryGet() &
      MultiAddress.init("/quic-v1").get()
  except QuicConfigError as exc:
    doAssert false, "invalid quic setup: " & $exc.msg
  except TLSCertificateError as exc:
    raise (ref QuicTransportError)(
      msg: "tlscert error in quic start: " & exc.msg, parent: exc
    )
  except QuicError as exc:
    raise
      (ref QuicTransportError)(msg: "quicerror in quic start: " & exc.msg, parent: exc)
  except TransportOsError as exc:
    raise (ref QuicTransportError)(
      msg: "transport error in quic start: " & exc.msg, parent: exc
    )
  self.running = true

method stop*(transport: QuicTransport) {.async: (raises: []).} =
  let conns = transport.connections[0 .. ^1]
  for c in conns:
    await c.close()

  if not transport.listener.isNil:
    try:
      await transport.listener.stop()
    except CatchableError as exc:
      trace "Error shutting down Quic transport", description = exc.msg
    transport.listener.destroy()
    transport.listener = nil

  transport.client = Opt.none(QuicClient)
  await procCall Transport(transport).stop()

proc wrapConnection(
    transport: QuicTransport, connection: QuicConnection
): QuicSession {.raises: [TransportOsError, MaError].} =
  let
    observedAddr =
      MultiAddress.init(connection.remoteAddress(), IPPROTO_UDP).get() &
      MultiAddress.init("/quic-v1").get()
    localAddr =
      MultiAddress.init(connection.localAddress(), IPPROTO_UDP).get() &
      MultiAddress.init("/quic-v1").get()
    session = QuicSession(
      connection: connection,
      observedAddr: Opt.some(observedAddr),
      localAddr: Opt.some(localAddr),
    )

  session.initStream()

  transport.connections.add(session)

  proc onClose() {.async: (raises: []).} =
    await noCancel session.join()
    transport.connections.keepItIf(it != session)
    trace "Cleaned up client"

  asyncSpawn onClose()

  return session

method accept*(
    self: QuicTransport
): Future[connection.Connection] {.
    async: (raises: [transport.TransportError, CancelledError])
.} =
  if not self.running:
    # stop accept only when transport is stopped (not when error occurs)
    raise newException(QuicTransportAcceptStopped, "Quic transport stopped")

  doAssert not self.listener.isNil, "call start() before calling accept()"

  try:
    let connection = await self.listener.accept()
    return self.wrapConnection(connection)
  except CancelledError as exc:
    raise exc
  except QuicError as exc:
    debug "Quic Error", description = exc.msg
  except MaError as exc:
    debug "Multiaddr Error", description = exc.msg
  except CatchableError as exc: # TODO: removing this requires async/raises in nim-quic
    info "Unexpected error accepting quic connection", description = exc.msg
  except TransportOsError as exc:
    debug "OS Error", description = exc.msg

method dial*(
    self: QuicTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[connection.Connection] {.
    async: (raises: [transport.TransportError, CancelledError])
.} =
  try:
    if not self.client.isSome:
      self.client = Opt.some(QuicClient.init(self.makeConfig(), rng = self.getRng()))

    let client = self.client.get()
    let quicConnection = await client.dial(initTAddress(address).tryGet)
    return self.wrapConnection(quicConnection)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise newException(QuicTransportDialError, "error in quic dial:" & e.msg, e)

method upgrade*(
    self: QuicTransport, conn: P2PConnection, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError]).} =
  let qs = QuicSession(conn)
  qs.peerId =
    if peerId.isSome:
      peerId.get()
    else:
      let certificates = qs.connection.certificates()
      let cert = parse(certificates[0])
      cert.peerId()

  let muxer = QuicMuxer(quicSession: qs, connection: conn)
  muxer.streamHandler = proc(conn: P2PConnection) {.async: (raises: []).} =
    trace "Starting stream handler"
    try:
      await self.upgrader.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      return
    except CatchableError as exc:
      trace "exception in stream handler", conn, msg = exc.msg
    finally:
      await conn.closeWithEOF()
    trace "Stream handler done", conn
  muxer.handleFut = muxer.handle()
  return muxer
