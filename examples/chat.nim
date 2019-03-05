import chronos, nimcrypto, strutils
import ../libp2p/daemon/daemonapi

const
  ConsoleAddress = "/tmp/console-chat.sock"
  ServerAddress = "/tmp/remote-chat.sock"
  ServerProtocols = @["/test-chat-stream"]

type
  CustomData = ref object
    api: DaemonAPI
    remotes: seq[StreamTransport]

proc threadMain(a: int) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## unix domain socket to main thread.
  var transp = waitFor connect(initTAddress(ConsoleAddress))

  while true:
    var line = stdin.readLine()
    let res = waitFor transp.write(line & "\r\n")

proc serveThread(server: StreamServer,
                 transp: StreamTransport) {.async.} =
  ## This procedure perform readin on local unix domain socket and
  ## sends data to remote clients.
  var udata = getUserData[CustomData](server)

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
          var peerId = PeerID.init(parts[1])
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
          asyncCheck remoteReader(stream.transp)
      elif line.startsWith("/search"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerID.init(parts[1])
          echo "= Searching for peer ", peerId.pretty()
          var id = await udata.api.dhtFindPeer(peerId)
          echo "= Peer " & parts[1] & " found at addresses:"
          for item in id.addresses:
            echo $item
      elif line.startsWith("/consearch"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerID.init(parts[1])
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
        quit(0)
      else:
        var msg = line & "\r\n"
        echo "<< ", line
        var pending = newSeq[Future[int]]()
        for item in udata.remotes:
          pending.add(item.write(msg))
        if len(pending) > 0:
          var results = await all(pending)
    except:
      break

proc main() {.async.} =
  var data = new CustomData
  data.remotes = newSeq[StreamTransport]()

  var lserver = createStreamServer(initTAddress(ConsoleAddress),
                                   serveThread, udata = data)
  lserver.start()
  var thread: Thread[int]
  thread.createThread(threadMain, 0)

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
  echo "= Your PeerID is ", id.peer.pretty()

when isMainModule:
  waitFor(main())
  while true:
    poll()
