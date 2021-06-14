when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import tables, strformat, strutils
import chronos
import ../libp2p/[switch,
                  multistream,
                  crypto/crypto,
                  protocols/identify,
                  connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress,
                  peerinfo,
                  peerid,
                  protocols/protocol,
                  protocols/secure/secure,
                  protocols/secure/secio,
                  muxers/muxer,
                  muxers/mplex/mplex]

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

# copied from https://github.com/status-im/nimbus-eth2/blob/0ed657e953740a92458f23033d47483ffa17ccb0/beacon_chain/eth2_network.nim#L109-L115
proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str)
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(MultiAddressError,
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
  asyncSpawn p.writeAndPrint() # execute the async function but does not block
  asyncSpawn p.readAndPrint()

proc processInput(rfd: AsyncFD) {.async.} =
  let transp = fromPipe(rfd)
  while true:
    let a = await transp.readLine()
    echo "You just entered: " & a

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc main() {.async.} =
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)

  await processInput(rfd)

when isMainModule:      # isMainModule = true when the module is compiled as the main file
  waitFor(main())
