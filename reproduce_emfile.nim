import chronos, posix
from chronos/transports/stream import StreamServer, accept, connect

proc main() {.async.} =
  var limit = RLimit(rlim_cur: 20, rlim_max: 20)
  discard setrlimit(RLIMIT_NOFILE, limit)

  let server = createStreamServer(initTAddress("127.0.0.1:0"))
  let listenAddr = server.localAddress()
  echo "Server listening on ", listenAddr

  var clients: seq[StreamTransport]

  # Async task to accept connections infinitely and log what happens
  proc acceptLoop() {.async.} =
    var count = 0
    var errorCount = 0
    while true:
      try:
        let _ = await server.accept()
        echo "Server accepted connection ", count
        inc count
      except CatchableError as e:
        inc errorCount
        if e.msg == "Server is already closed!":
          break
        if errorCount mod 10000 == 0:
          echo "Server accept error (x", errorCount, "): ", e.msg

  asyncSpawn acceptLoop()

  echo "Client starting connections..."
  try:
    for i in 0..<50:
      let c = await connect(listenAddr)
      clients.add(c)
      echo "Client connected ", i
  except CatchableError as e:
    echo "Client failed: ", e.msg, " type: ", $e.name

  echo "Waiting 5 seconds... Checking CPU usage."
  await sleepAsync(5.seconds)
  echo "Done"
  server.stop()
  server.close()

waitFor main()
