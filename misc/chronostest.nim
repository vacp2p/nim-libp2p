import chronos

const
  ReqMessage = "111111111111111111111111"
  RespMessage = "2222222222222222222222"
  Connections = 100

proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
  var respMessage = RespMessage & "\r\n"
  while true:
    var line = await transp.readLine()
    if line == "" and transp.atEof():
      break
    if line != ReqMessage:
      raise newException(ValueError, "Invalid request")
    let r = await transp.write(respMessage)
    doAssert(r == len(respMessage))
  await transp.closeWait()

proc readWrite(transp: StreamTransport) {.async.} =
  var reqMessage = ReqMessage & "\r\n"
  for i in 0 ..< 1000:
    let r = await transp.write(reqMessage)
    doAssert(r == len(reqMessage))
    var line = await transp.readLine()
    if line != RespMessage:
      raise newException(ValueError, "Invalid response")
  await transp.closeWait()

proc test(address: TransportAddress) {.async.} =
  var server = createStreamServer(address, serveClient, {ReuseAddr})
  var ta = server.localAddress()
  server.start()

  var connections = newSeq[Future[StreamTransport]](Connections)
  var pendings = newSeq[Future[void]](Connections)
  for i in 0 ..< Connections:
    connections[i] = connect(ta)

  await allFutures(connections)

  for i in 0 ..< Connections:
    if connections[i].failed():
      echo "connection failed"
    else:
      pendings[i] = readWrite(connections[i].read())

  var a = Moment.now()
  await allFutures(pendings)
  var b = Moment.now()
  echo "Time elapsed ", $(b - a)

  server.stop()
  await server.closeWait()


when isMainModule:
  waitFor test(initTAddress("0.0.0.0:0"))
