when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import tables, strformat, strutils, bearssl
import chronos                              # an efficient library for async
import ../libp2p/[switch,                   # manage transports, a single entry point for dialing and listening
                  multistream,              # tag stream with short header to identify it
                  crypto/crypto,            # cryptographic functions
                  errors,                   # error handling utilities
                  protocols/identify,       # identify the peer info of a peer
                  stream/connection,        # create and close stream read / write connections
                  transports/transport,     # listen and dial to other peers using p2p protocol
                  transports/tcptransport,  # listen and dial to other peers using client-server protocol
                  multiaddress,             # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
                  peerinfo,                 # manage the information of a peer, such as peer ID and public / private key
                  peerid,                   # Implement how peers interact
                  protocols/protocol,       # define the protocol base type
                  protocols/secure/secure,  # define the protocol of secure connection
                  protocols/secure/secio,   # define the protocol of secure input / output, allows encrypted communication that uses public keys to validate signed messages instead of a certificate authority like in TLS
                  muxers/muxer,             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
                  muxers/mplex/mplex]       # define some contants and message types for stream multiplexing

const ChatCodec = "/nim-libp2p/chat/1.0.0"
const DefaultAddr = "/ip4/127.0.0.1/tcp/55505"

const Help = """
  Commands: /[?|hep|connect|disconnect|exit]
  help: Prints this help
  connect: dials a remote peer
  disconnect: ends current session
  exit: closes the chat
"""

type ChatProto = ref object of LPProtocol
  switch: Switch          # a single entry point for dialing and listening to peer
  transp: StreamTransport # transport streams between read & write file descriptor
  conn: Connection        # create and close read & write stream
  connected: bool         # if the node is connected to another peer
  started: bool           # if the node has started


proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                         "Invalid bootstrap node multi-address")

proc dialPeer(p: ChatProto, address: string) {.async.} =
  let multiAddr = MultiAddress.initAddress(address);
  let parts = address.split("/")
  let remotePeer = PeerInfo.init(parts[^1],
                                 [multiAddr])

  echo &"dialing peer: {multiAddr}"
  p.conn = await p.switch.dial(remotePeer, ChatCodec)
  p.connected = true

proc readAndPrint(p: ChatProto) {.async.} =
  while true:
    while p.connected:
      # TODO: echo &"{p.id} -> "

      echo cast[string](await p.conn.readLp(1024))
    await sleepAsync(100.millis)

proc writeAndPrint(p: ChatProto) {.async.} =
  while true:
    if not p.connected:
      echo "type an address or wait for a connection:"
      echo "type /[help|?] for help"

    let line = await p.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not p.started:
      echo Help
      continue

    if line.startsWith("/disconnect"):
      echo "Ending current session"
      if p.connected and p.conn.closed.not:
        await p.conn.close()
      p.connected = false
    elif line.startsWith("/connect"):
      if p.connected:
        var yesno = "N"
        echo "a session is already in progress, do you want end it [y/N]?"
        yesno = await p.transp.readLine()
        if yesno.cmpIgnoreCase("y") == 0:
          await p.conn.close()
          p.connected = false
        elif yesno.cmpIgnoreCase("n") == 0:
          continue
        else:
          echo "unrecognized response"
          continue

      echo "enter address of remote peer"
      let address = await p.transp.readLine()
      if address.len > 0:
        await p.dialPeer(address)

    elif line.startsWith("/exit"):
      if p.connected and p.conn.closed.not:
        await p.conn.close()
        p.connected = false

      await p.switch.stop()
      echo "quitting..."
      quit(0)
    else:
      if p.connected:
        await p.conn.writeLp(line)
      else:
        try:
          if line.startsWith("/") and "ipfs" in line:
            await p.dialPeer(line)
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(p: ChatProto) {.async.} =
  asyncCheck p.writeAndPrint() # execute the async function but does not block
  asyncCheck p.readAndPrint()

proc newChatProto(switch: Switch, transp: StreamTransport): ChatProto =
  var chatproto = ChatProto(switch: switch, transp: transp, codecs: @[ChatCodec])

  # create handler for incoming connection
  proc handle(stream: Connection, proto: string) {.async.} =
    if chatproto.connected and not chatproto.conn.closed:
      echo "a chat session is already in progress - disconnecting!"
      await stream.close()
    else:
      chatproto.conn = stream
      chatproto.connected = true

  # assign the new handler
  chatproto.handler = handle
  return chatproto

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc processInput(rfd: AsyncFD, rng: ref BrHmacDrbgContext) {.async.} =
  let transp = fromPipe(rfd)

  let seckey = PrivateKey.random(RSA, rng[]).get()
  let peerInfo = PeerInfo.init(seckey)
  var localAddress = DefaultAddr
  while true:
    echo &"Type an address to bind to or Enter to use the default {DefaultAddr}"
    let a = await transp.readLine()
    try:
      if a.len > 0:
        peerInfo.addrs.add(Multiaddress.init(a).tryGet())
        break

      peerInfo.addrs.add(Multiaddress.init(localAddress).tryGet())
      break
    except:
      echo "invalid address"
      localAddress = DefaultAddr
      continue

  # a constructor for building different multiplexers under various connections
  proc createMplex(conn: Connection): Muxer =
    result = Mplex.init(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(TcpTransport.init())]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  let secureManagers = [Secure(newSecio(rng, seckey))]
  let switch = newSwitch(peerInfo,
                         transports,
                         identify,
                         muxers,
                         secureManagers)

  let chatProto = newChatProto(switch, transp)
  switch.mount(chatProto)
  let libp2pFuts = await switch.start()
  chatProto.started = true

  let id = $peerInfo.peerId
  echo "PeerID: " & id
  echo "listening on: "
  for a in peerInfo.addrs:
    echo &"{a}/ipfs/{id}"

  await chatProto.readWriteLoop()
  await allFuturesThrowing(libp2pFuts)

proc main() {.async.} =
  let rng = newRng() # Singe random number source for the whole application
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)

  await processInput(rfd, rng)

when isMainModule: # isMainModule = true when the module is compiled as the main file
  waitFor(main())
