# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## WebRtc transport implementation
## For now, only support WebRtc direct (ie browser to server)

{.push raises: [].}

import std/[sequtils]
import stew/results
import chronos, chronicles
import transport,
       ../errors,
       ../wire,
       ../multicodec,
       ../connmanager,
       ../multiaddress,
       ../stream/connection,
       ../upgrademngrs/upgrade,
       ../utility

logScope:
  topics = "libp2p webrtctransport"

export transport, results

const
  WebRtcTransportTrackerName* = "libp2p.webrtctransport"

# -- Message --
type
  MessageFlag = enum
    Fin = 0
    StopSending = 1
    ResetStream = 2
    FinAck = 3

  WebRtcMessage = object
    flag: Opt[MessageFlag]
    data: seq[byte]

proc decode(_: type WebRtcMessage, bytes: seq[byte]): Opt[WebRtcMessage] =
  var
    pb = initProtoBuffer(bytes)
    flagOrd: uint32
    res: WebRtcMessage
  if ? pb.getField(1, flagOrd):
    var flag: MessageFlag
    if flag.checkEnumAssign(flagOrd):
      res.flag = Opt.some(flag)

  discard ? pb.getField(2, res.data)
  Opt.some(res)

proc encode(msg: WebRtcMessage): seq[byte] =
  var pb = initProtoBuffer()

  msg.flag.withValue(val):
    pb.writeField(1, val)

  if msg.data.len > 0:
    pb.writeField(2, msg.data)

  pb.finish()
  pb.buffer

# -- Stream --
const MaxMessageSize = 16384 # 16KiB

type
  WebRtcState = enum
    Sending, Closing, Closed

  WebRtcStream = ref object of Connection
    dataChannel: DataChannel
    sendQueue: seq[(seq[byte], Future[void])]
    sendLoop: Future[void]
    readData: seq[byte]
    txState: WebRtcState
    rxState: WebRtcState

proc new(
    _: type WebRtcStream,
    dataChannel: DataChannel,
    oaddr: Opt[MultiAddress],
    peerId: PeerId): WebRtcStream =
  let stream = WebRtcStream(stream: stream, observedAddr: oaddr, peerId: peerId)
  procCall Connection(stream).initStream()
  stream

proc sender(s: WebRtcConnection) {.async.} =
  while s.sendQueue.len > 0:
    let (message, fut) = s.sendQueue.pop()
    #TODO handle exceptions
    await s.dataChannel.write(message)
    if not fut.isNil: fut.complete()

proc send(s: WebRtcConnection, msg: WebRtcMessage, fut: Future[void] = nil) =
  let wrappedMessage = msg.encode()
  s.sendQueue.insert((wrappedMessage, fut))

  if s.sendLoop == nil or s.sendLoop.finished:
    s.sendLoop = s.sender()

method write*(s: WebRtcConnection, msg: seq[byte]): Future[void] =
  # We need to make sure we send all of our data before another write
  # Otherwise, two concurrent writes could get intertwined
  # We avoid this by filling the s.sendQueue synchronously

  let retFuture = newFuture[void]("WebRtcConnection.write")
  if s.txState != Sending:
    retFuture.fail(newLPStreamClosedError())
    return retFuture

  var messages: seq[seq[byte]]
  while msg.len > MaxMessageSize - 16:
    let
      endOfMessage = MaxMessageSize - 16
      wrappedMessage = WebRtcMessage(data: msg[0 ..< endOfMessage])
    s.send(wrappedMessage)
    msg = msg[endOfMessage .. ^1]

  let
    wrappedMessage = WebRtcMessage(data: msg)
  s.send(wrappedMessage, retFuture)

  return retFuture

proc actuallyClose(s: WebRtcConnection) {.async.} =
  if s.rxState == Closed and s.txState == Closed and s.readData.len == 0:
    await s.conn.close()
    await procCall Connection(s).closeImpl()

method readOnce*(s: WebRtcConnection, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  while s.readData.len == 0:
    if s.rxState == Closed:
      s.atEof = true
      await s.actuallyClose()
      return 0

    let
      #TODO handle exceptions
      message = await s.conn.read()
      decoded = WebRtcMessage.decode(message)

    decoded.flag.withValue(flag):
      case flag:
      of Fin:
        # Peer won't send any more data
        s.rxState = Closed
        s.send(WebRtcMessage(flag: Opt.some(FinAck)))
      of FinAck:
        s.txState = Closed
        await s.actuallyClose()

    s.readData = decoded.data

  result = min(nbytes, s.readData.len)
  copyMem(pbytes, addr s.readData[0], toCopy)
  stream.cached = stream.cached[result..^1]

method closeImpl*(s: WebRtcConnection) {.async.} =
  s.send(WebRtcMessage(flag: Opt.some(Fin)))
  s.txState = Closing
  await s.join() #TODO ??

# -- Connection --
type WebRtcConnection = ref object of Connection
  connection: DataChannelConnection

method close*(conn: WebRtcConnection) {.async.} =
  #TODO
  discard

proc getStream*(conn: WebRtcConnection,
                direction: Direction): Future[WebRtcStream] {.async.} =
  var datachannel =
    case direction:
      of Direction.In:
        await conn.connection.incomingStream()
      of Direction.Out:
        await conn.connection.openStream()
  return WebRtcStream.new(datachannel, conn.observedAddr, conn.peerId)

# -- Muxer --
type WebRtcMuxer = ref object of Muxer
  webRtcConn: WebRtcConnection
  handleFut: Future[void]

method newStream*(m: WebRtcMuxer, name: string = "", lazy: bool = false): Future[Connection] {.async, gcsafe.} =
  return await m.webRtcConn.getStream(Direction.Out)

proc handleStream(m: WebRtcMuxer, chann: WebRtcStream) {.async.} =
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in mplex stream handler", msg = exc.msg
    await chann.close()

method handle*(m: WebRtcMuxer): Future[void] {.async, gcsafe.} =
  try:
    while not m.webRtcConn.atEof:
      let incomingStream = await m.webRtcConn.getStream(Direction.In)
      asyncSpawn m.handleStream(incomingStream)
  finally:
    await m.webRtcConn.close()

method close*(m: WebRtcMuxer) {.async, gcsafe.} =
  m.handleFut.cancel()
  await m.webRtcConn.close()

# -- Upgrader --
type WebRtcUpgrade = ref object of Upgrade

method upgrade*(
    self: WebRtcUpgrade,
    conn: Connection,
    direction: Direction,
    peerId: Opt[PeerId]): Future[Muxer] {.async.} =

  let webRtcConn = WebRtcConnection(conn)
  result = WebRtcMuxer(webRtcConn: webRtcConn)

  # Noise handshake
  let noiseHandler = self.secureManagers.filterIt(it of Noise)
  assert noiseHandler.len > 0

  let
    stream = webRtcConn.getStream(Out) #TODO add channelId: 0
    secureStream = noiseHandler[0].handshake(
      stream,
      initiator: true, # we are always the initiator in webrtc-direct
      peerId: peerId
      #TODO: add prelude data
    )

  # Peer proved its identity, we can close this
  await secureStream.close()
  await stream.close()

# -- Transport --
type
  WebRtcTransport* = ref object of Transport
    connectionsTimeout: Duration
    servers: seq[WebRtc]
    clients: array[Direction, seq[DataChannelConnection]]

  WebRtcTransportTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

  WebRtcTransportError* = object of transport.TransportError

proc setupWebRtcTransportTracker(): WebRtcTransportTracker {.gcsafe, raises: [].}

proc getWebRtcTransportTracker(): WebRtcTransportTracker {.gcsafe.} =
  result = cast[WebRtcTransportTracker](getTracker(WebRtcTransportTrackerName))
  if isNil(result):
    result = setupWebRtcTransportTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getWebRtcTransportTracker()
  result = "Opened tcp transports: " & $tracker.opened & "\n" &
           "Closed tcp transports: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getWebRtcTransportTracker()
  result = (tracker.opened != tracker.closed)

proc setupWebRtcTransportTracker(): WebRtcTransportTracker =
  result = new WebRtcTransportTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(WebRtcTransportTrackerName, result)

proc new*(
  T: typedesc[WebRtcTransport],
  upgrade: Upgrade,
  connectionsTimeout = 10.minutes): T {.public.} =

  let
    transport = T(
      upgrader: WebRtcUpgrade(secureManagers: upgrade.secureManagers),
      connectionsTimeout: connectionsTimeout)

  return transport

method start*(
  self: WebRtcTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  if self.running:
    warn "WebRtc transport already running"
    return

  await procCall Transport(self).start(addrs)
  trace "Starting WebRtc transport"
  inc getWebRtcTransportTracker().opened

  for i, ma in addrs:
    if not self.handles(ma):
      trace "Invalid address detected, skipping!", address = ma
      continue

    let
      transportAddress = initTAddress(ma)
      server = WebRtc.new(transportAddress)
    server.start()

    self.servers &= server

    self.addrs[i] = MultiAddress.init(server.getLocalAddress(), IPPROTO_UDP).tryGet()
    #TODO add webrtc-direct & certhash

    trace "Listening on", address = self.addrs[i]

proc connHandler(self: WebRtcTransport,
                 client: DataChannelConnection,
                 observedAddr: Opt[MultiAddress],
                 dir: Direction): Future[Connection] {.async.} =

  trace "Handling ws connection", address = $observedAddr,
                                   dir = $dir,
                                   clients = self.clients[Direction.In].len +
                                   self.clients[Direction.Out].len

  let conn: Connection =
    WebRtcConnection.new(
      client = client,
      dir = dir,
      observedAddr = observedAddr,
      timeout = self.connectionsTimeout
    )

  proc onClose() {.async.} =
    try:
      let futs = @[client.join(), conn.join()]
      await futs[0] or futs[1]
      for f in futs:
        if not f.finished: await f.cancelAndWait() # cancel outstanding join()

      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn

      self.clients[dir].keepItIf( it != client )
      await allFuturesThrowing(
        conn.close(), client.closeWait())

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  self.clients[dir].add(client)
  asyncSpawn onClose()

  return conn

method accept*(self: WebRtcTransport): Future[Connection] {.async, gcsafe.} =
  if not self.running:
    raise newTransportClosedError()

  #TODO handle errors
  if self.acceptFuts.len <= 0:
    self.acceptFuts = self.servers.mapIt(it.accept())

  if self.acceptFuts.len <= 0:
    return

  let
    finished = await one(self.acceptFuts)
    index = self.acceptFuts.find(finished)

  self.acceptFuts[index] = self.servers[index].accept()

  let transp = await finished
  try:
    let observedAddr = MultiAddress.init(transp.remoteAddress).tryGet()
    return await self.connHandler(transp, Opt.some(observedAddr), Direction.In)
  except CancelledError as exc:
    transp.close()
    raise exc
  except CatchableError as exc:
    debug "Failed to handle connection", exc = exc.msg
    transp.close()

method handles*(t: WebRtcTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return WebRtcDirect2.match(address)
