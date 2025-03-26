import std/sequtils
import pkg/chronos
import pkg/chronicles
import pkg/quic
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

const alpn = "libp2p"

# Stream
type QuicStream* = ref object of P2PConnection
  stream: Stream
  cached: seq[byte]

proc new(
    _: type QuicStream, stream: Stream, oaddr: Opt[MultiAddress], peerId: PeerId
): QuicStream =
  let quicstream = QuicStream(stream: stream, observedAddr: oaddr, peerId: peerId)
  procCall P2PConnection(quicstream).initStream()
  quicstream

template mapExceptions(body: untyped) =
  try:
    body
  except QuicError:
    raise newLPStreamEOFError()
  except CatchableError:
    raise newLPStreamEOFError()

method readOnce*(
    stream: QuicStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  try:
    if stream.cached.len == 0:
      stream.cached = await stream.stream.read()
    result = min(nbytes, stream.cached.len)
    copyMem(pbytes, addr stream.cached[0], result)
    stream.cached = stream.cached[result ..^ 1]
  except CatchableError as exc:
    raise newLPStreamEOFError()

{.push warning[LockLevel]: off.}
method write*(
    stream: QuicStream, bytes: seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  mapExceptions(await stream.stream.write(bytes))

{.pop.}

method closeImpl*(stream: QuicStream) {.async: (raises: []).} =
  try:
    await stream.stream.close()
  except CatchableError as exc:
    discard
  await procCall P2PConnection(stream).closeImpl()

# Session
type QuicSession* = ref object of P2PConnection
  connection: QuicConnection

method close*(session: QuicSession) {.async: (raises: []).} =
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
    return QuicStream.new(stream, session.observedAddr, session.peerId)
  except CatchableError as exc:
    # TODO: incomingStream is using {.async.} with no raises
    raise (ref QuicTransportError)(msg: exc.msg, parent: exc)

method getWrapped*(self: QuicSession): P2PConnection =
  nil

# Muxer
type QuicMuxer = ref object of Muxer
  quicSession: QuicSession
  handleFut: Future[void]

method newStream*(
    m: QuicMuxer, name: string = "", lazy: bool = false
): Future[P2PConnection] {.
    async: (raises: [CancelledError, LPStreamError, MuxerError])
.} =
  try:
    return await m.quicSession.getStream(Direction.Out)
  except CatchableError as exc:
    raise newException(MuxerError, exc.msg, exc)

proc handleStream(m: QuicMuxer, chann: QuicStream) {.async: (raises: []).} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in mplex stream handler", msg = exc.msg
    await chann.close()

method handle*(m: QuicMuxer): Future[void] {.async: (raises: []).} =
  try:
    while not m.quicSession.atEof:
      let incomingStream = await m.quicSession.getStream(Direction.In)
      asyncSpawn m.handleStream(incomingStream)
  except CatchableError as exc:
    trace "Exception in mplex handler", msg = exc.msg

method close*(m: QuicMuxer) {.async: (raises: []).} =
  try:
    await m.quicSession.close()
    m.handleFut.cancelSoon()
  except CatchableError as exc:
    discard

# Transport
type QuicUpgrade = ref object of Upgrade

type QuicTransport* = ref object of Transport
  listener: Listener
  client: QuicClient
  privateKey: PrivateKey
  connections: seq[P2PConnection]
  rng: ref HmacDrbgContext

proc makeCertificateVerifier(): CertificateVerifier =
  proc certificateVerifier(certificatesDer: seq[seq[byte]]): bool =
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

func new*(_: type QuicTransport, u: Upgrade, privateKey: PrivateKey): QuicTransport =
  return QuicTransport(upgrader: QuicUpgrade(ms: u.ms), privateKey: privateKey)

method handles*(transport: QuicTransport, address: MultiAddress): bool {.raises: [].} =
  if not procCall Transport(transport).handles(address):
    return false
  QUIC_V1.match(address)

method start*(
    self: QuicTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError]).} =
  doAssert self.listener.isNil, "start() already called"
  #TODO handle multiple addr

  let pubkey = self.privateKey.getPublicKey().valueOr:
    doAssert false, "could not obtain public key"
    return

  let keypair = KeyPair(seckey: self.privateKey, pubkey: pubkey)
  let certTuple = generate(keypair, encodingFormat = EncodingFormat.PEM)

  try:
    if self.rng.isNil:
      self.rng = newRng()
    let tlsConfig = TLSConfig.init(
      certTuple[0], certTuple[1], @[alpn], Opt.some(makeCertificateVerifier())
    )
    self.client = QuicClient.init(tlsConfig, rng = self.rng)
    self.listener =
      QuicServer.init(tlsConfig, rng = self.rng).listen(initTAddress(addrs[0]).tryGet)
    await procCall Transport(self).start(addrs)
    self.addrs[0] =
      MultiAddress.init(self.listener.localAddress(), IPPROTO_UDP).tryGet() &
      MultiAddress.init("/quic-v1").get()
  except QuicConfigError as exc:
    doAssert false, "invalid quic setup: " & $exc.msg
  except QuicError as exc:
    raise (ref QuicTransportError)(msg: exc.msg, parent: exc)
  except TransportOsError as exc:
    raise (ref QuicTransportError)(msg: exc.msg, parent: exc)
  self.running = true

method stop*(transport: QuicTransport) {.async: (raises: []).} =
  if transport.running:
    for c in transport.connections:
      await c.close()
    await procCall Transport(transport).stop()
    try:
      await transport.listener.stop()
    except CatchableError as exc:
      trace "Error shutting down Quic transport", description = exc.msg
    transport.listener.destroy()
    transport.running = false
    transport.listener = nil

proc wrapConnection(
    transport: QuicTransport, connection: QuicConnection
): QuicSession {.raises: [TransportOsError, LPError].} =
  let
    remoteAddr = connection.remoteAddress()
    observedAddr =
      MultiAddress.init(remoteAddr, IPPROTO_UDP).get() &
      MultiAddress.init("/quic-v1").get()
    session = QuicSession(connection: connection, observedAddr: Opt.some(observedAddr))

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
  doAssert not self.listener.isNil, "call start() before calling accept()"
  try:
    let connection = await self.listener.accept()
    return self.wrapConnection(connection)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise (ref QuicTransportError)(msg: e.msg, parent: e)

method dial*(
    self: QuicTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[connection.Connection] {.
    async: (raises: [transport.TransportError, CancelledError])
.} =
  try:
    let quicConnection = await self.client.dial(initTAddress(address).tryGet)
    return self.wrapConnection(quicConnection)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise newException(QuicTransportDialError, e.msg, e)

method upgrade*(
    self: QuicTransport, conn: P2PConnection, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError]).} =
  let qs = QuicSession(conn)
  if peerId.isSome:
    qs.peerId = peerId.get()

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
