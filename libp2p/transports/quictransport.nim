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
  ../utils/opt,
  ../utils/future
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
  LsquicStream = lsquic.Stream
  QuicTransportError* = object of transport.TransportError
  QuicTransportDialError* = object of transport.TransportDialError
  QuicTransportAcceptStopped* = object of QuicTransportError

  QuicStream* = ref object of P2PConnection
    session: QuicSession
    stream: LsquicStream

  QuicSession* = ref object of P2PConnection
    connection: QuicConnection
    streams: HashSet[QuicStream]
    when defined(libp2p_agents_metrics):
      tracked: bool

func hash*(s: QuicStream): Hash =
  cast[pointer](s).hash

const alpn = "libp2p"

initializeLsquic()

proc new(
    _: type QuicStream,
    stream: LsquicStream,
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
  self.session

when defined(libp2p_agents_metrics):
  proc trackPeerIdentity(s: QuicSession) =
    if not s.tracked and s.shortAgent.len > 0:
      libp2p_peers_identity.inc(labelValues = [s.shortAgent])
      s.tracked = true

  proc untrackPeerIdentity(s: QuicSession) =
    if s.tracked:
      libp2p_peers_identity.dec(labelValues = [s.shortAgent])
      s.tracked = false

method readOnce*(
    stream: QuicStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if stream.wasResetLocally:
    raise newLPStreamClosedError()

  if stream.atEof:
    raise newLPStreamRemoteClosedError()

  var readLen: int
  try:
    readLen = await stream.stream.readOnce(cast[ptr byte](pbytes), nbytes)
  except StreamError as e:
    raise newLPStreamResetError()

  if readLen == 0:
    stream.isEof = true
    return 0

  stream.activity = true
  libp2p_network_bytes.inc(readLen.int64, labelValues = ["in"])
  when defined(libp2p_agents_metrics):
    stream.session.trackPeerIdentity()
    if stream.session.tracked:
      libp2p_peers_traffic_read.inc(readLen.int64, labelValues = [stream.shortAgent])
  return readLen

method write*(
    stream: QuicStream, bytes: sink seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  if stream.wasResetLocally:
    raise newLPStreamClosedError()

  let bytesLen = bytes.len
  try:
    await stream.stream.write(bytes)
    libp2p_network_bytes.inc(bytesLen.int64, labelValues = ["out"])
    when defined(libp2p_agents_metrics):
      stream.session.trackPeerIdentity()
      if stream.session.tracked:
        libp2p_peers_traffic_write.inc(
          bytesLen.int64, labelValues = [stream.shortAgent]
        )
  except StreamError:
    raise newLPStreamResetError()

method closeWrite*(stream: QuicStream) {.async: (raises: []).} =
  ## Close the write side of the QUIC stream
  try:
    await stream.stream.close()
  except CancelledError, StreamError:
    discard

method resetImpl*(stream: QuicStream) {.async: (raises: []).} =
  stream.stream.abort()
  stream.isEof = true
  stream.session.streams.excl(stream)
  await procCall P2PConnection(stream).closeImpl()

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
  when defined(libp2p_agents_metrics):
    session.untrackPeerIdentity()
  await procCall P2PConnection(session).close()

proc getStream(
    session: QuicSession, direction = Direction.In
): Future[QuicStream] {.async: (raises: [CancelledError, ConnectionError]).} =
  if session.closed:
    raise newException(ConnectionClosedError, "session is closed")

  var stream: LsquicStream
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
  # QuicSession is the underlying transport connection; returning nil ends
  # wrapper traversal for callers that walk through layered connections.
  nil

# Muxer
type QuicMuxer* = ref object of Muxer
  session: QuicSession
  handleFut: Future[void]
  handlerFuts: seq[Future[void]] # per-stream streamHandler invocations

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
): Future[MuxedStream] {.async: (raises: [CancelledError, LPStreamError, MuxerError]).} =
  try:
    return await m.session.getStream(Direction.Out)
  except ConnectionError as e:
    raise newException(MuxerError, "error in newStream: " & e.msg, e)

method getStreams*(m: QuicMuxer): seq[MuxedStream] {.gcsafe.} =
  var streams = newSeqOfCap[MuxedStream](m.session.streams.len)
  for s in m.session.streams:
    streams.add(s)
  return streams

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
      m.handlerFuts.keepItIf(not it.finished())
      m.handlerFuts.add(handleStream(stream))
    except ConnectionClosedError:
      break # stop handling, connection was closed
    except CancelledError:
      continue # keep handling, until connection is closed
    except ConnectionError as e:
      # keep handling, until connection is closed. 
      # this stream failed but we need to keep handling for other streams.
      trace "QuicMuxer.handler got error while opening stream", msg = e.msg

  if not m.session.isClosed:
    await m.session.close()

method close*(m: QuicMuxer) {.async: (raises: []).} =
  try:
    # Close the session first: the accept loop only exits once the session is
    # closed, so cancelling handleFut beforehand would hang cancelAndWait.
    await m.session.close()
    if not isNil(m.handleFut):
      await noCancel m.handleFut.cancelAndWait()
    # Cancel in-flight handlers rather than just awaiting them, so each stream is
    # torn down deterministically here (handlers run closeWithEOF on cancel)
    # instead of being aborted lazily during GC finalization.
    await noCancel m.handlerFuts.cancelAndWait()
    m.handlerFuts = @[]
  except CatchableError:
    discard

# Transport
type QuicUpgrade = ref object of Upgrade
  connManager: Opt[ConnManager]

type CertGenerator =
  proc(kp: KeyPair): CertificateX509 {.gcsafe, raises: [TLSCertificateError].}

type QuicAcceptType = typeof(default(QuicEndpoint).accept())

type QuicTransport* = ref object of Transport
  listeners: seq[QuicEndpoint]
  acceptFuts: seq[QuicAcceptType]
  dialEndpoint4: Opt[QuicEndpoint]
  dialEndpoint6: Opt[QuicEndpoint]
  privateKey: PrivateKey
  connections: HashSet[P2PConnection]
  rng: Rng
  certGenerator: CertGenerator
  closeFuts: seq[Future[void]] # per-session onClose tasks

proc parseCertificate(certificatesDer: seq[seq[byte]]): Opt[P2pCertificate] =
  if certificatesDer.len != 1:
    trace "CertificateVerifier: expected one certificate in the chain",
      cert_count = certificatesDer.len
    return Opt.none(P2pCertificate)

  let cert =
    try:
      parse(certificatesDer[0])
    except CertificateParsingError as e:
      trace "CertificateVerifier: failed to parse certificate", msg = e.msg
      return Opt.none(P2pCertificate)

  Opt.some(cert)

proc verifyCertificates(certificatesDer: seq[seq[byte]]): bool =
  let cert = parseCertificate(certificatesDer).valueOr:
    return false

  if cert.verifiedIdentityKey().isNone:
    trace "CertificateVerifier: certificate verification failed"
    return false
  true

proc verifyCertificatesForPeer(
    certificatesDer: seq[seq[byte]], expectedPeerId: PeerId
): bool =
  let cert = parseCertificate(certificatesDer).valueOr:
    return false

  if not cert.verify(expectedPeerId):
    trace "CertificateVerifier: certificate did not match expected peer id",
      expectedPeerId = expectedPeerId
    return false
  true

proc certificateVerifier(_: string, certificatesDer: seq[seq[byte]]): bool {.gcsafe.} =
  verifyCertificates(certificatesDer)

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
  let certVerifier = CustomCertificateVerifier.init(certificateVerifier)
  let tlsConfig = TLSConfig.new(
    cert.certificate,
    cert.privateKey,
    @[alpn].toHashSet(),
    Opt.some(CertificateVerifier(certVerifier)),
  )
  return tlsConfig

proc toMultiAddress(ta: TransportAddress): MultiAddress {.raises: [MaError].} =
  ## Returns quic MultiAddress from TransportAddress
  MultiAddress.init(ta, IPPROTO_UDP).get() & MultiAddress.init("/quic-v1").get()

method start*(
    self: QuicTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  doAssert self.listeners.len == 0, "start() already called"

  let addrsTa = self.toTransportAddress(addrs).valueOr:
    raise newException(TransportStartError, $error)

  var listenMAs: seq[MultiAddress]
  var initialized = false
  try:
    let tlsConfig = self.makeConfig()
    for ta in addrsTa:
      let endpoint = QuicEndpoint.new(tlsConfig, ta)
      self.listeners.add(endpoint)
      listenMAs.add(toMultiAddress(endpoint.localAddress()))
    initialized = true
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
  finally:
    if not initialized:
      for listener in self.listeners:
        await noCancel listener.stop()
      self.listeners = @[]

  await procCall Transport(self).start(listenMAs)

method stop*(transport: QuicTransport) {.async: (raises: []).} =
  let futs = transport.connections.mapIt(it.close())
  await noCancel allFutures(futs)

  discard await noCancel allFinished(transport.closeFuts)
  transport.closeFuts = @[]

  var endpointStops: seq[Future[void]]
  transport.dialEndpoint4.withValue(endpoint):
    endpointStops.add(endpoint.stop())
  transport.dialEndpoint6.withValue(endpoint):
    endpointStops.add(endpoint.stop())
  await noCancel allFutures(endpointStops)

  transport.dialEndpoint4 = Opt.none(QuicEndpoint)
  transport.dialEndpoint6 = Opt.none(QuicEndpoint)

  await noCancel allFutures(transport.listeners.mapIt(it.stop()))
  transport.listeners = @[]
  transport.acceptFuts = @[]

  await procCall Transport(transport).stop()

proc wrapConnection(
    transport: QuicTransport, connection: QuicConnection, transportDir: Direction
): QuicSession {.raises: [].} =
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

  transport.closeFuts.keepItIf(not it.finished())
  transport.closeFuts.add(onClose())

  return session

method accept*(
    self: QuicTransport
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  if not self.running:
    # stop accept only when transport is stopped (not when error occurs)
    raise newException(QuicTransportAcceptStopped, "Quic transport stopped")

  doAssert self.listeners.len > 0, "call start() before calling accept()"

  if self.acceptFuts.len == 0:
    # initially start accept from all listeners
    self.acceptFuts = self.listeners.mapIt(it.accept())

  let finished =
    try:
      let acceptFutsCopy = self.acceptFuts
      await one(acceptFutsCopy)
    except ValueError:
      raiseAssert "acceptFuts should never be empty"
    except CancelledError as exc:
      self.acceptFuts.cancelSoon()
      raise exc

  if not self.running or self.listeners.len == 0: # Stopped while waiting
    raise newTransportClosedError()

  # becasue some listener has accepted we need to run 
  # accept manually in the place for this listner again 
  # so that it keeps accepting for future method calls
  let index = self.acceptFuts.find(finished)
  self.acceptFuts[index] = self.listeners[index].accept()

  try:
    let conn = await finished
    return self.wrapConnection(conn, Direction.In)
  except QuicError as exc:
    debug "Quic Error", description = exc.msg
  except common.TransportError as exc:
    debug "Transport Error", description = exc.msg
  except TransportOsError as exc:
    debug "OS Error", description = exc.msg

proc listenerEndpointFor(
    self: QuicTransport, address: TransportAddress
): Opt[QuicEndpoint] {.raises: [TransportOsError].} =
  var matchedEndpoint = Opt.none(QuicEndpoint)
  for endpoint in self.listeners:
    if endpoint.localAddress().family == address.family:
      if matchedEndpoint.isSome():
        return Opt.none(QuicEndpoint)
      matchedEndpoint = Opt.some(endpoint)

  matchedEndpoint

proc dialOnlyEndpointFor(
    self: QuicTransport, family: AddressFamily
): QuicEndpoint {.raises: [TLSCertificateError, QuicError, TransportOsError].} =
  case family
  of AddressFamily.IPv4:
    if self.dialEndpoint4.isNone():
      self.dialEndpoint4 = Opt.some(QuicEndpoint.new(self.makeConfig(), family))
    self.dialEndpoint4.get()
  of AddressFamily.IPv6:
    if self.dialEndpoint6.isNone():
      self.dialEndpoint6 = Opt.some(QuicEndpoint.new(self.makeConfig(), family))
    self.dialEndpoint6.get()
  else:
    raise newException(QuicError, "client supports only IPv4/IPv6 address")

proc dialEndpointFor(
    self: QuicTransport, address: TransportAddress
): QuicEndpoint {.raises: [TLSCertificateError, QuicError, TransportOsError].} =
  let listenerEndpoint = self.listenerEndpointFor(address)
  if listenerEndpoint.isSome():
    return listenerEndpoint.get()

  self.dialOnlyEndpointFor(address.family)

method dial*(
    self: QuicTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  let taAddress =
    try:
      initTAddress(address).tryGet
    except LPError as e:
      raise newException(
        QuicTransportDialError, "error in quic dial: invald address: " & e.msg, e
      )

  try:
    let endpoint = self.dialEndpointFor(taAddress)
    let quicConnection = await endpoint.dial(taAddress)
    peerId.withValue(expectedPeerId):
      if not verifyCertificatesForPeer(quicConnection.certificates(), expectedPeerId):
        quicConnection.abort()
        raise newException(
          QuicTransportDialError,
          "error in quic dial: certificate does not match expected peer id",
        )
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
    self: QuicTransport, conn: RawConn, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError]).} =
  let muxer = QuicMuxer.new(conn, peerId)
  muxer.streamHandler = proc(stream: MuxedStream) {.async: (raises: []).} =
    trace "Starting stream handler"
    try:
      let quicUpgrader = QuicUpgrade(self.upgrader)
      quicUpgrader.connManager.withValue(connManager):
        let ready = await connManager.waitForPeerReady(stream.peerId)
        if not ready:
          debug "Timed out waiting for peer ready before handling stream", stream
          return
      await self.upgrader.ms.handle(stream) # handle incoming stream
    except CancelledError:
      return
    except CatchableError as exc:
      trace "exception in stream handler", stream, msg = exc.msg
    finally:
      await stream.closeWithEOF()
      trace "Stream handler done", stream
  muxer.handleFut = muxer.handle()
  return muxer
