# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[hashes, sets, sequtils]
import chronos, chronicles, metrics, results
import lsquic
import
  ../wire,
  ../connmanager,
  ../multiaddress,
  ../multicodec,
  ../muxers/muxer,
  ../stream/connection,
  ../upgrademngrs/upgrade,
  ../utility
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
  QuicConnection = lsquic.Connection
  QuicTransportError* = object of transport.TransportError
  QuicTransportDialError* = object of transport.TransportDialError
  QuicTransportAcceptStopped* = object of QuicTransportError

  QuicStream* = ref object of P2PConnection
    session: QuicSession
    stream: Stream

  QuicSession* = ref object of P2PConnection
    connection: QuicConnection
    streams: HashSet[QuicStream]

func hash*(s: QuicStream): Hash =
  cast[pointer](s).hash

const alpn = "libp2p"

initializeLsquic()

proc new(
    _: type QuicStream,
    stream: Stream,
    dir: Direction,
    session: QuicSession,
    oaddr: Opt[MultiAddress],
    laddr: Opt[MultiAddress],
    peerId: PeerId,
): QuicStream =
  let quicstream = QuicStream(
    session: session,
    stream: stream,
    timeout: 0.millis, # QUIC handles idle timeout at the transport layer
    observedAddr: oaddr,
    localAddr: laddr,
    peerId: peerId,
  )
  quicstream.objName = "QuicStream"
  quicstream.dir = dir
  procCall P2PConnection(quicstream).initStream()
  quicstream

method getWrapped*(self: QuicStream): P2PConnection =
  self

method readOnce*(
    stream: QuicStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if stream.atEof:
    raise newLPStreamRemoteClosedError()

  let readLen =
    try:
      await stream.stream.readOnce(cast[ptr byte](pbytes), nbytes)
    except StreamError as e:
      raise (ref LPStreamError)(msg: "error in readOnce: " & e.msg, parent: e)

  if readLen == 0:
    stream.isEof = true
    return 0

  stream.activity = true
  libp2p_network_bytes.inc(readLen.int64, labelValues = ["in"])
  return readLen

method write*(
    stream: QuicStream, bytes: seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  try:
    await stream.stream.write(bytes)
    libp2p_network_bytes.inc(bytes.len.int64, labelValues = ["out"])
  except StreamError:
    raise newLPStreamEOFError()

method closeWrite*(stream: QuicStream) {.async: (raises: []).} =
  ## Close the write side of the QUIC stream
  try:
    await stream.stream.close()
  except CancelledError, StreamError:
    discard

method closeImpl*(stream: QuicStream) {.async: (raises: []).} =
  try:
    await stream.stream.close()
  except CancelledError, StreamError:
    discard
  stream.session.streams.excl(stream)
  await procCall P2PConnection(stream).closeImpl()

# Session
method closed*(session: QuicSession): bool {.raises: [].} =
  procCall P2PConnection(session).isClosed or session.connection.isClosed

method close*(session: QuicSession) {.async: (raises: []).} =
  let streams = session.streams
  session.streams.clear()
  await noCancel allFutures(streams.mapIt(it.close()))
  session.connection.close()
  await procCall P2PConnection(session).close()

proc getStream(
    session: QuicSession, direction = Direction.In
): Future[QuicStream] {.async: (raises: [CancelledError, ConnectionError]).} =
  if session.closed:
    raise newException(ConnectionClosedError, "session is closed")

  var stream: Stream
  case direction
  of Direction.In:
    stream = await session.connection.incomingStream()
  of Direction.Out:
    stream = await session.connection.openStream()

  let qs = QuicStream.new(
    stream, direction, session, session.observedAddr, session.localAddr, session.peerId
  )
  when defined(libp2p_agents_metrics):
    qs.shortAgent = session.shortAgent

  # Inherit transportDir from parent session for GossipSub outbound peer tracking
  qs.transportDir = session.transportDir

  session.streams.incl(qs)
  return qs

method getWrapped*(self: QuicSession): P2PConnection =
  self

# Muxer
type QuicMuxer* = ref object of Muxer
  session: QuicSession
  handleFut: Future[void]

proc new*(
    _: type QuicMuxer, conn: P2PConnection, peerId: Opt[PeerId] = Opt.none(PeerId)
): QuicMuxer {.raises: [CertificateParsingError, LPError].} =
  let session = QuicSession(conn)
  session.peerId = peerId.valueOr:
    let certificates = session.connection.certificates()
    if certificates.len != 1:
      raise (ref QuicTransportError)(msg: "expected one certificate in connection")
    let cert = parse(certificates[0])
    cert.peerId()
  QuicMuxer(session: session, connection: conn)

when defined(libp2p_agents_metrics):
  method setShortAgent*(m: QuicMuxer, shortAgent: string) =
    m.session.shortAgent = shortAgent
    for s in m.session.streams:
      s.shortAgent = shortAgent
    m.connection.shortAgent = shortAgent

method newStream*(
    m: QuicMuxer, name: string = "", lazy: bool = false
): Future[P2PConnection] {.
    async: (raises: [CancelledError, LPStreamError, MuxerError])
.} =
  try:
    return await m.session.getStream(Direction.Out)
  except ConnectionError as e:
    raise newException(MuxerError, "error in newStream: " & e.msg, e)

method handle*(m: QuicMuxer): Future[void] {.async: (raises: []).} =
  proc handleStream(stream: QuicStream) {.async: (raises: []).} =
    ## call the muxer stream handler for this channel
    ##
    await m.streamHandler(stream)
    trace "finished handling stream"
    doAssert(stream.closed, "connection not closed by handler!")

  while not (m.session.atEof or m.session.closed):
    try:
      let stream = await m.session.getStream(Direction.In)
      asyncSpawn handleStream(stream)
    except ConnectionClosedError:
      break # stop handling, connection was closed
    except CancelledError:
      continue # keep handling, until connection is closed
    except ConnectionError as e:
      # keep handling, until connection is closed. 
      # this stream failed but we need to keep handling for other streams.
      trace "QuicMuxer.handler got error while opening stream", msg = e.msg

method close*(m: QuicMuxer) {.async: (raises: []).} =
  try:
    await m.session.close()
    if not isNil(m.handleFut):
      m.handleFut.cancelSoon()
  except CatchableError:
    discard

# Transport
type QuicUpgrade = ref object of Upgrade
  connManager: Opt[ConnManager]

type CertGenerator =
  proc(kp: KeyPair): CertificateX509 {.gcsafe, raises: [TLSCertificateError].}

type QuicTransport* = ref object of Transport
  listener: Listener
  client: Opt[QuicClient]
  privateKey: PrivateKey
  connections: HashSet[P2PConnection]
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

proc new*(
    _: type QuicTransport,
    u: Upgrade,
    privateKey: PrivateKey,
    connManager: ConnManager = nil,
): QuicTransport =
  let self = QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms, connManager: connManager.toOpt()),
    privateKey: privateKey,
    certGenerator: defaultCertGenerator,
  )
  procCall Transport(self).initialize()
  self

proc new*(
    _: type QuicTransport,
    u: Upgrade,
    privateKey: PrivateKey,
    certGenerator: CertGenerator,
    connManager: ConnManager = nil,
): QuicTransport =
  let self = QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms, connManager: connManager.toOpt()),
    privateKey: privateKey,
    certGenerator: certGenerator,
  )
  procCall Transport(self).initialize()
  self

method handles*(transport: QuicTransport, address: MultiAddress): bool {.raises: [].} =
  if not procCall Transport(transport).handles(address):
    return false
  QUIC_V1.match(address)

proc makeConfig(self: QuicTransport): TLSConfig =
  let pubkey = self.privateKey.getPublicKey().valueOr:
    raiseAssert "could not obtain public key"

  let cert = self.certGenerator(KeyPair(seckey: self.privateKey, pubkey: pubkey))
  let certVerifier = makeCertificateVerifier()
  let tlsConfig = TLSConfig.new(
    cert.certificate, cert.privateKey, @[alpn].toHashSet(), Opt.some(certVerifier)
  )
  return tlsConfig

proc getRng(self: QuicTransport): ref HmacDrbgContext =
  if self.rng.isNil:
    self.rng = newRng()

  return self.rng

proc toMultiAddress(ta: TransportAddress): MultiAddress {.raises: [MaError].} =
  ## Returns quic MultiAddress from TransportAddress
  MultiAddress.init(ta, IPPROTO_UDP).get() & MultiAddress.init("/quic-v1").get()

method start*(
    self: QuicTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  doAssert self.listener.isNil, "start() already called"
  # TODO(#1663): handle multiple addr

  try:
    let server = QuicServer.new(self.makeConfig())
    self.listener = server.listen(initTAddress(addrs[0]).tryGet)
    let listenMA = @[toMultiAddress(self.listener.localAddress())]
    await procCall Transport(self).start(listenMA)
  except QuicConfigError as exc:
    raiseAssert "invalid quic setup: " & $exc.msg
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

method stop*(transport: QuicTransport) {.async: (raises: []).} =
  let futs = transport.connections.mapIt(it.close())
  await noCancel allFutures(futs)

  if not transport.listener.isNil:
    try:
      await transport.listener.stop()
    except CatchableError as exc:
      trace "Error shutting down Quic transport", description = exc.msg
    transport.listener = nil

  transport.client.withValue(client):
    await noCancel client.stop()

  transport.client = Opt.none(QuicClient)
  await procCall Transport(transport).stop()

proc wrapConnection(
    transport: QuicTransport, connection: QuicConnection, transportDir: Direction
): QuicSession {.raises: [TransportOsError].} =
  var observedAddr: MultiAddress
  var localAddr: MultiAddress
  try:
    observedAddr = toMultiAddress(connection.remoteAddress())
    localAddr = toMultiAddress(connection.localAddress())
  except MaError as e:
    raiseAssert "Multiaddr Error" & e.msg

  let session = QuicSession(
    dir: transportDir,
    objName: "QuicSession",
    connection: connection,
    observedAddr: Opt.some(observedAddr),
    localAddr: Opt.some(localAddr),
  )
  session.initStream()

  # Set the transport direction for outbound peer tracking in GossipSub 1.1
  session.transportDir = transportDir

  transport.connections.incl(session)

  proc onClose() {.async: (raises: []).} =
    await noCancel session.join()
    transport.connections.excl(session)
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
    return self.wrapConnection(connection, Direction.In)
  except QuicError as exc:
    debug "Quic Error", description = exc.msg
  except common.TransportError as exc:
    debug "Transport Error", description = exc.msg
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
  let taAddress =
    try:
      initTAddress(address).tryGet
    except LPError as e:
      raise newException(
        QuicTransportDialError, "error in quic dial: invald address: " & e.msg, e
      )

  try:
    if not self.client.isSome:
      self.client = Opt.some(QuicClient.new(self.makeConfig()))

    let client = self.client.get()
    let quicConnection = await client.dial(taAddress)
    return self.wrapConnection(quicConnection, Direction.Out)
  except QuicConfigError as e:
    raise newException(
      QuicTransportDialError, "error in quic dial: invalid tls config:" & e.msg, e
    )
  except TLSCertificateError as e:
    raise newException(
      QuicTransportDialError, "error in quic dial: tls certificate error:" & e.msg, e
    )
  except TransportOsError as e:
    raise newException(QuicTransportDialError, "error in quic dial:" & e.msg, e)
  except DialError as e:
    raise newException(QuicTransportDialError, "error in quic dial:" & e.msg, e)
  except QuicError as e:
    raise newException(QuicTransportDialError, "error in quic dial:" & e.msg, e)

method upgrade*(
    self: QuicTransport, conn: P2PConnection, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError]).} =
  let muxer = QuicMuxer.new(conn, peerId)
  muxer.streamHandler = proc(conn: P2PConnection) {.async: (raises: []).} =
    trace "Starting stream handler"
    try:
      let quicUpgrader = QuicUpgrade(self.upgrader)
      quicUpgrader.connManager.withValue(connManager):
        let ready = await connManager.waitForPeerReady(conn.peerId)
        if not ready:
          debug "Timed out waiting for peer ready before handling stream", conn
          return
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
