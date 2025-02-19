import std/sequtils
import pkg/chronos
import pkg/chronicles
import pkg/quic
import ../multiaddress
import ../multicodec
import ../stream/connection
import ../wire
import ../muxers/muxer
import ../upgrademngrs/upgrade
import ./transport

export multiaddress
export multicodec
export connection
export transport

logScope:
  topics = "libp2p quictransport"

type
  P2PConnection = connection.Connection
  QuicConnection = quic.Connection

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

method close*(session: QuicSession) {.async, base.} =
  await session.connection.close()
  await procCall P2PConnection(session).close()

proc getStream*(
    session: QuicSession, direction = Direction.In
): Future[QuicStream] {.async.} =
  var stream: Stream
  case direction
  of Direction.In:
    stream = await session.connection.incomingStream()
  of Direction.Out:
    stream = await session.connection.openStream()
    await stream.write(@[]) # QUIC streams do not exist until data is sent
  return QuicStream.new(stream, session.observedAddr, session.peerId)

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

proc handleStream(m: QuicMuxer, chann: QuicStream) {.async.} =
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
    m.handleFut.cancel()
  except CatchableError as exc:
    discard

# Transport
type QuicUpgrade = ref object of Upgrade

type QuicTransport* = ref object of Transport
  listener: Listener
  connections: seq[P2PConnection]

func new*(_: type QuicTransport, u: Upgrade): QuicTransport =
  QuicTransport(upgrader: QuicUpgrade(ms: u.ms))

method handles*(transport: QuicTransport, address: MultiAddress): bool =
  if not procCall Transport(transport).handles(address):
    return false
  QUIC_V1.match(address)

method start*(transport: QuicTransport, addrs: seq[MultiAddress]) {.async.} =
  doAssert transport.listener.isNil, "start() already called"
  #TODO handle multiple addr
  transport.listener = listen(initTAddress(addrs[0]).tryGet)
  await procCall Transport(transport).start(addrs)
  transport.addrs[0] =
    MultiAddress.init(transport.listener.localAddress(), IPPROTO_UDP).tryGet() &
    MultiAddress.init("/quic-v1").get()
  transport.running = true

method stop*(transport: QuicTransport) {.async.} =
  if transport.running:
    for c in transport.connections:
      await c.close()
    await procCall Transport(transport).stop()
    await transport.listener.stop()
    transport.running = false
    transport.listener = nil

proc wrapConnection(
    transport: QuicTransport, connection: QuicConnection
): P2PConnection {.raises: [Defect, TransportOsError, LPError].} =
  let
    remoteAddr = connection.remoteAddress()
    observedAddr =
      MultiAddress.init(remoteAddr, IPPROTO_UDP).get() &
      MultiAddress.init("/quic-v1").get()
    conres = QuicSession(connection: connection, observedAddr: Opt.some(observedAddr))
  conres.initStream()

  transport.connections.add(conres)
  proc onClose() {.async.} =
    await conres.join()
    transport.connections.keepItIf(it != conres)
    trace "Cleaned up client"

  asyncSpawn onClose()
  return conres

method accept*(transport: QuicTransport): Future[P2PConnection] {.async.} =
  doAssert not transport.listener.isNil, "call start() before calling accept()"
  let connection = await transport.listener.accept()
  return transport.wrapConnection(connection)

method dial*(
    transport: QuicTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[P2PConnection] {.async.} =
  let connection = await dial(initTAddress(address).tryGet)
  return transport.wrapConnection(connection)

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
