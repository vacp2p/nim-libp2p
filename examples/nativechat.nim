import tables, options, sequtils, algorithm, strformat, os, strutils
import chronos, chronicles
import ../libp2p/switch,
       ../libp2p/multistream,
       ../libp2p/crypto/crypto,
       ../libp2p/protocols/identify,
       ../libp2p/connection,
       ../libp2p/transports/[transport, tcptransport],
       ../libp2p/multiaddress,
       ../libp2p/peerinfo,
       ../libp2p/peer,
       ../libp2p/protocols/protocol,
       ../libp2p/protocols/secure/secure,
       ../libp2p/protocols/secure/secio,
       ../libp2p/protocols/pubsub/pubsub,
       ../libp2p/protocols/pubsub/floodsub,
       ../libp2p/muxers/muxer,
       ../libp2p/muxers/mplex/mplex,
       ../libp2p/muxers/mplex/types

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

const ChatCodec = "/nim-libp2p/chat/1.0.0"
type
  CustomData = ref object
    consoleFd: AsyncFD
    serveFut: Future[void]

  ChatProto = ref object of LPProtocol
    customData*: CustomData
    switch: Switch
    transp: StreamTransport
    isConnected: AsyncEvent
    conn: Connection
    client: bool
    connected: bool

# forward declaration
proc readWriteLoop(p: ChatProto) {.async, gcsafe.}
proc readAndPrint(p: ChatProto) {.async, gcsafe.} =
  while true:
    while p.connected:
      echo cast[string](await p.conn.readLp())
    await sleepAsync(100)

proc dialPeer(p: ChatProto, address: string) {.async, gcsafe.} =
  var parts = address.split("/")
  if parts.len == 11 and parts[^2] != "ipfs" and parts[^2] != "p2p":
    quit("invalid or incompelete peerId")

  var remotePeer: PeerInfo
  remotePeer.peerId = some(PeerID.init(parts[^1]))
  remotePeer.addrs.add(MultiAddress.init(address))

  echo &"dialing peer: {address}"
  p.conn = await p.switch.dial(remotePeer, ChatCodec)
  p.connected = true

proc writeAndPrint(p: ChatProto) {.async, gcsafe.} = 
  while true:
    if p.connected:
      echo "type your message:"
    else:
      echo "type an address or wait for a connection:"

    var line = await p.transp.readLine()
    if p.connected:
      await p.conn.writeLp(line)
    else:
      try:
        await p.dialPeer(line)
      except:
        echo &"unable to dial {line}"
        echo getCurrentExceptionMsg()

proc readWriteLoop(p: ChatProto) {.async, gcsafe.} =
    asyncCheck p.writeAndPrint()
    asyncCheck p.readAndPrint()

method init(p: ChatProto) {.gcsafe.} =
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} = 
    p.conn = stream
    p.connected = true

  p.codec = ChatCodec
  p.handler = handle

proc newChatProto(switch: Switch, transp: StreamTransport): ChatProto = 
  new result
  result.switch = switch
  result.transp = transp
  result.init()

proc threadMain(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  var transp = fromPipe(wfd)
 
  while true:
    var line = stdin.readLine()
    echo line
    let res = waitFor transp.write(line & "\r\n")

proc serveThread(customData: CustomData) {.async.} =
  var transp = fromPipe(customData.consoleFd)

  let seckey = PrivateKey.random(RSA)
  var peerInfo: PeerInfo
  peerInfo.peerId = some(PeerID.init(seckey))
  var localAddress = "/ip4/127.0.0.1/tcp/55505"
  echo "Type an address to bind to or Enter use the default /ip4/127.0.0.1/tcp/55505"
  let a = await transp.readLine()
  if a.len > 0:
    localAddress = a
 
  peerInfo.addrs.add(Multiaddress.init(localAddress))
  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  var mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  var transports = @[Transport(newTransport(TcpTransport))]
  var muxers = [(MplexCodec, mplexProvider)].toTable()
  var identify = newIdentify(peerInfo)
  # var secureManagers = @[Secure(newSecIo(seckey.getKey()))]
  var switch = newSwitch(peerInfo, transports, identify, muxers)

  var libp2pFuts = await switch.start()
  var chatProto = newChatProto(switch, transp)
  switch.mount(chatProto)
  echo "PeerID: " & peerInfo.peerId.get().pretty
  echo "listening on: "
  for a in switch.peerInfo.addrs:
    echo a

  await chatProto.readWriteLoop()
  await allFutures(libp2pFuts)

proc main() {.async.} =
  var data = new CustomData

  var (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")
  
  data.consoleFd = rfd
  data.serveFut = serveThread(data)
  var thread: Thread[AsyncFD]
  thread.createThread(threadMain, wfd)
  await data.serveFut

when isMainModule:
  waitFor(main())
