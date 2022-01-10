import chronos, nimcrypto, strutils
import ../../libp2p/daemon/daemonapi

## nim c -r --threads:on chat.nim
when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

const
  ServerProtocols = @["/test-chat-stream"]

type
  CustomData = ref object
    api: DaemonAPI
    remotes: seq[StreamTransport]
    consoleFd: AsyncFD
    serveFut: Future[void]

proc threadMain(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  var transp = fromPipe(wfd)

  while true:
    var line = stdin.readLine()
    let res = waitFor transp.write(line & "\r\n")

proc serveThread(udata: CustomData) {.async.} =
  ## This procedure perform reading on pipe and sends data to remote clients.
  var transp = fromPipe(udata.consoleFd)

  proc remoteReader(transp: StreamTransport) {.async.} =
    while true:
      var line = await transp.readLine()
      if len(line) == 0:
        break
      echo ">> ", line

  while true:
    try:
      var line = await transp.readLine()
      if line.startsWith("/connect"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerId.init(parts[1])
          var address = MultiAddress.init(multiCodec("p2p-circuit"))
          address &= MultiAddress.init(multiCodec("p2p"), peerId)
          echo "= Searching for peer ", peerId.pretty()
          var id = await udata.api.dhtFindPeer(peerId)
          echo "= Peer " & parts[1] & " found at addresses:"
          for item in id.addresses:
            echo $item
          echo "= Connecting to peer ", $address
          await udata.api.connect(peerId, @[address], 30)
          echo "= Opening stream to peer chat ", parts[1]
          var stream = await udata.api.openStream(peerId, ServerProtocols)
          udata.remotes.add(stream.transp)
          echo "= Connected to peer chat ", parts[1]
          asyncSpawn remoteReader(stream.transp)
      elif line.startsWith("/search"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerId.init(parts[1])
          echo "= Searching for peer ", peerId.pretty()
          var id = await udata.api.dhtFindPeer(peerId)
          echo "= Peer " & parts[1] & " found at addresses:"
          for item in id.addresses:
            echo $item
      elif line.startsWith("/consearch"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerId.init(parts[1])
          echo "= Searching for peers connected to peer ", parts[1]
          var peers = await udata.api.dhtFindPeersConnectedToPeer(peerId)
          echo "= Found ", len(peers), " connected to peer ", parts[1]
          for item in peers:
            var peer = item.peer
            var addresses = newSeq[string]()
            var relay = false
            for a in item.addresses:
              addresses.add($a)
              if a.protoName() == "/p2p-circuit":
                relay = true
                break
            if relay:
              echo peer.pretty(), " * ",  " [", addresses.join(", "), "]"
            else:
              echo peer.pretty(), " [", addresses.join(", "), "]"
      elif line.startsWith("/exit"):
        break
      else:
        var msg = line & "\r\n"
        echo "<< ", line
        var pending = newSeq[Future[int]]()
        for item in udata.remotes:
          pending.add(item.write(msg))
        if len(pending) > 0:
          var results = await all(pending)
    except:
      echo getCurrentException().msg

proc main() {.async.} =
  var data = new CustomData
  data.remotes = newSeq[StreamTransport]()

  var (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  data.consoleFd = rfd

  data.serveFut = serveThread(data)
  var thread: Thread[AsyncFD]
  thread.createThread(threadMain, wfd)

  echo "= Starting P2P node"
  data.api = await newDaemonApi({DHTFull, Bootstrap})
  await sleepAsync(3000)
  var id = await data.api.identity()

  proc streamHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
    echo "= Peer ", stream.peer.pretty(), " joined chat"
    data.remotes.add(stream.transp)
    while true:
      var line = await stream.transp.readLine()
      if len(line) == 0:
        break
      echo ">> ", line

  await data.api.addHandler(ServerProtocols, streamHandler)
  echo "= Your PeerId is ", id.peer.pretty()
  await data.serveFut

when isMainModule:
  waitFor(main())
