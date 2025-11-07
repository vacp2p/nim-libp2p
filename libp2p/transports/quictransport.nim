# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
  if stream.atEof:
    raise newLPStreamRemoteClosedError()

  if stream.cached.len == 0:
    try:
      stream.cached = await stream.stream.read()
      if stream.cached.len == 0:
        stream.isEof = true
        return 0
    except QuicError as e:
      raise (ref LPStreamError)(msg: "error in readOnce: " & e.msg, parent: e)

  stream.activity = true

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
  except quic.ClosedStreamError:
    raise newLPStreamRemoteClosedError()
  except QuicError as e:
    raise (ref LPStreamError)(msg: "error in quic stream write: " & e.msg, parent: e)

{.pop.}

method closeWrite*(stream: QuicStream) {.async: (raises: []).} =
  ## Close the write side of the QUIC stream
  try:
    await stream.stream.closeWrite()
  except CancelledError, QuicError:
    discard

method closeImpl*(stream: QuicStream) {.async: (raises: []).} =
  try:
    await stream.stream.close()
  except CancelledError, QuicError:
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
  var stream: Stream
  try:
    case direction
    of Direction.In:
      stream = await session.connection.incomingStream()
    of Direction.Out:
      stream = await session.connection.openStream()
  except CancelledError as exc:
    raise (ref QuicTransportError)(msg: "cancelled getStream: " & exc.msg, parent: exc)
  except QuicError as exc:
    raise (ref QuicTransportError)(msg: "error in getStream: " & exc.msg, parent: exc)

  let qs =
    QuicStream.new(stream, session.observedAddr, session.localAddr, session.peerId)
  when defined(libp2p_agents_metrics):
    qs.shortAgent = session.shortAgent

  # Inherit transportDir from parent session for GossipSub outbound peer tracking
  qs.transportDir = session.transportDir

  session.streams.add(qs)
  return qs

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
  except QuicTransportError as exc:
    raise newException(MuxerError, "error in newStream: " & exc.msg, exc)

method handle*(m: QuicMuxer): Future[void] {.async: (raises: []).} =
  proc handleStream(chann: QuicStream) {.async: (raises: []).} =
    ## call the muxer stream handler for this channel
    ##
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")

  try:
    while not m.quicSession.atEof:
      let stream = await m.quicSession.getStream(Direction.In)
      asyncSpawn handleStream(stream)
  except QuicTransportError as exc:
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
  let self = QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms),
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
): QuicTransport =
  let self = QuicTransport(
    upgrader: QuicUpgrade(ms: u.ms),
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

proc maFromTa(ta: TransportAddress): MultiAddress {.raises: [MaError].} =
  ## Returns quic MultiAddress from TransportAddress
  MultiAddress.init(ta, IPPROTO_UDP).get() & MultiAddress.init("/quic-v1").get()

method start*(
    self: QuicTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  doAssert self.listener.isNil, "start() already called"
  # TODO(#1663): handle multiple addr

  try:
    let server = QuicServer.init(self.makeConfig(), self.getRng())
    self.listener = server.listen(initTAddress(addrs[0]).tryGet)
    let listenMA = @[maFromTa(self.listener.localAddress())]
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
    transport: QuicTransport, connection: QuicConnection, transportDir: Direction
): QuicSession {.raises: [TransportOsError].} =
  var observedAddr: MultiAddress
  var localAddr: MultiAddress
  try:
    observedAddr = maFromTa(connection.remoteAddress())
    localAddr = maFromTa(connection.localAddress())
  except MaError as e:
    raiseAssert "Multiaddr Error" & e.msg

  let session = QuicSession(
    connection: connection,
    observedAddr: Opt.some(observedAddr),
    localAddr: Opt.some(localAddr),
  )
  session.initStream()

  # Set the transport direction for outbound peer tracking in GossipSub 1.1
  session.transportDir = transportDir

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
    return self.wrapConnection(connection, Direction.In)
  except QuicError as exc:
    debug "Quic Error", description = exc.msg
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
      self.client = Opt.some(QuicClient.init(self.makeConfig(), self.getRng()))

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
  except QuicError as e:
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
