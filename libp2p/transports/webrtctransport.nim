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
import stew/[endians2, byteutils, objects, results]
import chronos, chronicles
import transport,
       ../errors,
       ../wire,
       ../multicodec,
       ../multihash,
       ../multibase,
       ../protobuf/minprotobuf,
       ../connmanager,
       ../muxers/muxer,
       ../multiaddress,
       ../stream/connection,
       ../upgrademngrs/upgrade,
       ../protocols/secure/noise,
       ../utility

import webrtc/webrtc, webrtc/datachannel, webrtc/dtls/dtls

logScope:
  topics = "libp2p webrtctransport"

export transport, results

const charset = toSeq("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/+".items)
proc genUfrag*(rng: ref HmacDrbgContext, size: int): seq[byte] =
  # https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md?plain=1#L73-L77
  result = newSeq[byte](size)
  for resultIndex in 0..<size:
    let charsetIndex = rng[].generate(uint) mod charset.len()
    result[resultIndex] = charset[charsetIndex].ord().uint8

const
  WebRtcTransportTrackerName* = "libp2p.webrtctransport"
  MaxMessageSize = 16384 # 16KiB; from the WebRtc-direct spec

# -- Message --
# Implementation of the libp2p's WebRTC message defined here:
# https://github.com/libp2p/specs/blob/master/webrtc/README.md?plain=1#L60-L79

type
  MessageFlag = enum
    ## Flags to support half-closing and reset of streams.
    ## - Fin: Sender will no longer send messages
    ## - StopSending: Sender will no longer read messages.
    ##   Received messages are discarded
    ## - ResetStream: Sender abruptly terminates the sending part of the stream.
    ##   Receiver MAY discard any data that it already received on that stream
    ## - FinAck: Acknowledges the previous receipt of a message with the Fin flag set.
    Fin = 0
    StopSending = 1
    ResetStream = 2
    FinAck = 3

  WebRtcMessage = object
    flag: Opt[MessageFlag]
    data: seq[byte]

proc decode(_: type WebRtcMessage, bytes: seq[byte]): Opt[WebRtcMessage] =
  ## Decoding WebRTC Message from raw data
  var
    pb = initProtoBuffer(bytes)
    flagOrd: uint32
    res: WebRtcMessage
  if ? pb.getField(1, flagOrd).toOpt():
    var flag: MessageFlag
    if flag.checkedEnumAssign(flagOrd):
      res.flag = Opt.some(flag)

  discard ? pb.getField(2, res.data).toOpt()
  Opt.some(res)

proc encode(msg: WebRtcMessage): seq[byte] =
  ## Encoding WebRTC Message to raw data
  var pb = initProtoBuffer()

  msg.flag.withValue(val):
    pb.write(1, uint32(val))

  if msg.data.len > 0:
    pb.write(2, msg.data)

  pb.finish()
  pb.buffer

# -- Raw WebRTC Stream --
# All the data written to or read from a WebRtcStream should be length-prefixed
# so `readOnce`/`write` WebRtcStream implementation must either recode
# `readLP`/`writeLP`, or implement a `RawWebRtcStream` on which we can
# directly use `readLP` and `writeLP`. The second solution is the less redundant,
# so it's the one we've chosen.

type
  RawWebRtcStream = ref object of Connection
    dataChannel: DataChannelStream
    readData: seq[byte]

proc new(_: type RawWebRtcStream, dataChannel: DataChannelStream): RawWebRtcStream =
  RawWebRtcStream(dataChannel: dataChannel)

method closeImpl*(s: RawWebRtcStream): Future[void] =
  # TODO: close datachannel
  discard

method write*(s: RawWebRtcStream, msg: seq[byte]): Future[void] =
  trace "RawWebrtcStream write", msg, len=msg.len()
  s.dataChannel.write(msg)

method readOnce*(s: RawWebRtcStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  # TODO:
  # if s.isClosed:
  #   raise newLPStreamEOFError()

  if s.readData.len() == 0:
    let rawData = await s.dataChannel.read()
    s.readData = rawData
  trace "readOnce RawWebRtcStream", data = s.readData, nbytes

  result = min(nbytes, s.readData.len)
  copyMem(pbytes, addr s.readData[0], result)
  s.readData = s.readData[result..^1]

# -- Stream --

type
  WebRtcState = enum
    Sending, Closing, Closed

  WebRtcStream = ref object of Connection
    rawStream: RawWebRtcStream
    sendQueue: seq[(seq[byte], Future[void])]
    sendLoop: Future[void]
    readData: seq[byte]
    txState: WebRtcState # Transmission
    rxState: WebRtcState # Reception

proc new(
    _: type WebRtcStream,
    dataChannel: DataChannelStream,
    oaddr: Opt[MultiAddress],
    peerId: PeerId): WebRtcStream =
  let stream = WebRtcStream(rawStream: RawWebRtcStream.new(dataChannel),
                            observedAddr: oaddr, peerId: peerId)
  procCall Connection(stream).initStream()
  stream

proc sender(s: WebRtcStream) {.async.} =
  while s.sendQueue.len > 0:
    let (message, fut) = s.sendQueue.pop()
    #TODO handle exceptions
    await s.rawStream.writeLp(message)
    if not fut.isNil: fut.complete()

proc send(s: WebRtcStream, msg: WebRtcMessage, fut: Future[void] = nil) =
  let wrappedMessage = msg.encode()
  s.sendQueue.insert((wrappedMessage, fut))

  if s.sendLoop == nil or s.sendLoop.finished:
    s.sendLoop = s.sender()

method write*(s: WebRtcStream, msg2: seq[byte]): Future[void] =
  # We need to make sure we send all of our data before another write
  # Otherwise, two concurrent writes could get intertwined
  # We avoid this by filling the s.sendQueue synchronously
  var msg = msg2
  trace "WebrtcStream write", msg, len=msg.len()
  let retFuture = newFuture[void]("WebRtcStream.write")
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

proc actuallyClose(s: WebRtcStream) {.async.} =
  debug "stream closed", rxState=s.rxState, txState=s.txState
  if s.rxState == Closed and s.txState == Closed and s.readData.len == 0:
    #TODO add support to DataChannel
    #await s.dataChannel.close()
    await procCall Connection(s).closeImpl()

method readOnce*(s: WebRtcStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.rxState == Closed:
    raise newLPStreamEOFError()

  while s.readData.len == 0 or nbytes == 0:
    # Check if there's no data left in readData or if nbytes is equal to 0
    # in order to  read an eventual Fin or FinAck
    if s.rxState == Closed:
      await s.actuallyClose()
      return 0

    let
      #TODO handle exceptions
      message = await s.rawStream.readLp(MaxMessageSize)
      decoded = WebRtcMessage.decode(message).tryGet()

    s.readData = s.readData.concat(decoded.data)

    decoded.flag.withValue(flag):
      case flag:
      of Fin:
        # Peer won't send any more data
        s.rxState = Closed
        s.send(WebRtcMessage(flag: Opt.some(FinAck)))
      of FinAck:
        s.txState = Closed
        await s.actuallyClose()
        if nbytes == 0:
          return 0
      else: discard

  result = min(nbytes, s.readData.len)
  copyMem(pbytes, addr s.readData[0], result)
  s.readData = s.readData[result..^1]

method closeImpl*(s: WebRtcStream) {.async.} =
  s.send(WebRtcMessage(flag: Opt.some(Fin)))
  s.txState = Closing
  while s.txState != Closed:
    discard await s.readOnce(nil, 0)

# -- Connection --

type WebRtcConnection = ref object of Connection
  connection: DataChannelConnection
  remoteAddress: MultiAddress

method close*(conn: WebRtcConnection) {.async.} =
  #TODO
  discard

proc new(
    _: type WebRtcConnection,
    conn: DataChannelConnection,
    observedAddr: Opt[MultiAddress]
    ): WebRtcConnection =
  let co = WebRtcConnection(connection: conn, observedAddr: observedAddr)
  procCall Connection(co).initStream()
  co

proc getStream*(conn: WebRtcConnection,
                direction: Direction,
                noiseHandshake: bool = false): Future[WebRtcStream] {.async.} =
  var datachannel =
    case direction:
      of Direction.In:
        await conn.connection.accept()
      of Direction.Out:
        await conn.connection.openStream(noiseHandshake)
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

#TODO add atEof

method handle*(m: WebRtcMuxer): Future[void] {.async, gcsafe.} =
  try:
    #while not m.webRtcConn.atEof:
    while true:
      let incomingStream = await m.webRtcConn.getStream(Direction.In)
      asyncSpawn m.handleStream(incomingStream)
  finally:
    await m.webRtcConn.close()

method close*(m: WebRtcMuxer) {.async, gcsafe.} =
  m.handleFut.cancel()
  await m.webRtcConn.close()

# -- Upgrader --

type
  WebRtcStreamHandler = proc(conn: Connection): Future[void] {.gcsafe, raises: [].}
  WebRtcUpgrade = ref object of Upgrade
    streamHandler: WebRtcStreamHandler

method upgrade*(
    self: WebRtcUpgrade,
    conn: Connection,
    direction: Direction,
    peerId: Opt[PeerId]): Future[Muxer] {.async.} =

  let webRtcConn = WebRtcConnection(conn)
  result = WebRtcMuxer(connection: conn, webRtcConn: webRtcConn)

  # Noise handshake
  let noiseHandler = self.secureManagers.filterIt(it of Noise)
  assert noiseHandler.len > 0

  let xx = "libp2p-webrtc-noise:".toBytes()
  let localCert = MultiHash.digest("sha2-256", webRtcConn.connection.conn.conn.localCertificate()).get().data.buffer
  let remoteCert = MultiHash.digest("sha2-256", webRtcConn.connection.conn.conn.remoteCertificate()).get().data.buffer
  ((Noise)noiseHandler[0]).commonPrologue = xx & remoteCert & localCert
  echo "=> ", ((Noise)noiseHandler[0]).commonPrologue

  let
    stream = await webRtcConn.getStream(Out, true)
    secureStream = await noiseHandler[0].handshake(
      stream,
      initiator = true, # we are always the initiator in webrtc-direct
      peerId = peerId
    )

  # Peer proved its identity, we can close this
  await secureStream.close()
  await stream.close()

  result.streamHandler = self.streamHandler
  result.handler = result.handle()

# -- Transport --

type
  WebRtcTransport* = ref object of Transport
    connectionsTimeout: Duration
    servers: seq[WebRtc]
    acceptFuts: seq[Future[DataChannelConnection]]
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

  let upgrader = WebRtcUpgrade(ms: upgrade.ms, secureManagers: upgrade.secureManagers)
  upgrader.streamHandler = proc(conn: Connection)
    {.async, gcsafe, raises: [].} =
    # TODO: replace echo by trace and find why it fails compiling
    echo "Starting stream handler"#, conn
    try:
      await upgrader.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      echo "exception in stream handler", exc.msg#, conn, msg = exc.msg
    finally:
      await conn.closeWithEOF()
    echo "Stream handler done"#, conn

  let
    transport = T(
      upgrader: upgrader,
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
      transportAddress = initTAddress(ma[0..1].tryGet()).tryGet()
      server = WebRtc.new(transportAddress)
    server.listen()

    self.servers &= server

    let
      cert = server.dtls.localCertificate()
      certHash = MultiHash.digest("sha2-256", cert).get().data.buffer
      encodedCertHash = MultiBase.encode("base64", certHash).get()
    self.addrs[i] = MultiAddress.init(server.udp.laddr, IPPROTO_UDP).tryGet() &
      MultiAddress.init(multiCodec("webrtc-direct")).tryGet() &
      MultiAddress.init(multiCodec("certhash"), certHash).tryGet()

    trace "Listening on", address = self.addrs[i]

proc connHandler(
    self: WebRtcTransport,
    client: DataChannelConnection,
    observedAddr: Opt[MultiAddress],
    dir: Direction
  ): Future[Connection] {.async.} =
  trace "Handling webrtc connection", address = $observedAddr, dir = $dir,
    clients = self.clients[Direction.In].len + self.clients[Direction.Out].len

  let conn: Connection =
    WebRtcConnection.new(
      conn = client,
     # dir = dir,
      observedAddr = observedAddr
     # timeout = self.connectionsTimeout
    )

  proc onClose() {.async.} =
    try:
      let futs = @[conn.join(), conn.join()] #TODO that's stupid
      await futs[0] or futs[1]
      for f in futs:
        if not f.finished: await f.cancelAndWait() # cancel outstanding join()

      trace "Cleaning up client"# TODO ?: , addrs = $client.remoteAddress,
                                #   conn

      self.clients[dir].keepItIf( it != client )
      #TODO
      #await allFuturesThrowing(
      #  conn.close(), client.closeWait())

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
  trace "Accept WebRTC Transport"

  let transp = await finished
  try:
    #TODO add remoteAddress to DataChannelConnection
    #let observedAddr = MultiAddress.init(transp.remoteAddress).tryGet() #TODO add /webrtc-direct
    let observedAddr = MultiAddress.init("/ip4/127.0.0.1").tryGet()
    return await self.connHandler(transp, Opt.some(observedAddr), Direction.In)
  except CancelledError as exc:
    #TODO
    #transp.close()
    raise exc
  except CatchableError as exc:
    debug "Failed to handle connection", exc = exc.msg
    #TODO
    #transp.close()

method handles*(t: WebRtcTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return WebRtcDirect2.match(address)
