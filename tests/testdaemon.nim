import unittest
import asyncdispatch2
import ../libp2p/daemon/daemonapi

proc identitySpawnTest(): Future[bool] {.async.} =
  var api = await newDaemonApi(sockpath = "/tmp/p2pd-1.sock")
  var data = await api.identity()
  await api.close()
  result = true

proc connectStreamTest(): Future[bool] {.async.} =
  var api1 = await newDaemonApi(sockpath = "/tmp/p2pd-1.sock")
  var api2 = await newDaemonApi(sockpath = "/tmp/p2pd-2.sock")

  var id1 = await api1.identity()
  var id2 = await api2.identity()

  var protos = @["/test-stream"]
  var test = "TEST STRING"

  var testFuture = newFuture[string]("test.future")

  proc streamHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
    var line = await stream.transp.readLine()
    testFuture.complete(line)

  await api2.addHandler(protos, streamHandler)
  await api1.connect(id2.peer, id2.addresses)
  var stream = await api1.openStream(id2.peer, protos)
  let sent = await stream.transp.write(test & "\r\n")
  doAssert(sent == len(test) + 2)
  var check = await wait(testFuture, 10000)
  doAssert(check == test)
  await api1.close()
  await api2.close()
  result = true

proc provideBadCidTest(): Future[bool] {.async.} =
  var cid = newSeq[byte](10)
  var api = await newDaemonApi({DHTFull})
  try:
    await api.dhtProvide(cid)
    result = false
  except DaemonRemoteError:
    result = true

when isMainModule:
  suite "libp2p-daemon test suite":
    test "Simple spawn and get identity test":
      check:
        waitFor(identitySpawnTest()) == true
    test "Connect/Accept peer/stream test":
      check:
        waitFor(connectStreamTest()) == true
    test "DHT provide bad CID test":
      check:
        waitFor(provideBadCidTest()) == true
