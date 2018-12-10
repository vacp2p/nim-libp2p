import unittest
import asyncdispatch2
import ../libp2p/daemon/daemonapi

proc identitySpawnTest(): Future[bool] {.async.} =
  var api = await newDaemonApi()
  var data = await api.identity()
  await api.close()
  result = true

proc connectStreamTest(): Future[bool] {.async.} =
  var api1 = await newDaemonApi()
  var api2 = await newDaemonApi()

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
  echo await api1.listPeers()
  var stream = await api1.openStream(id2.peer, protos)
  let sent = await stream.transp.write(test & "\r\n")
  doAssert(sent == len(test) + 2)
  var check = await wait(testFuture, 10000)
  doAssert(check == test)
  await stream.close()
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
  finally:
    await api.close()

proc pubsubTest(f: set[P2PDaemonFlags]): Future[bool] {.async.} =
  var pubsubData = "TEST MESSAGE"
  var msgData = cast[seq[byte]](pubsubData)
  var api1, api2: DaemonAPI
  if PSGossipSub in f:
    api1 = await newDaemonApi(f, gossipsubHeartbeatInterval = 100,
                              gossipsubHeartbeatDelay = 100)
    api2 = await newDaemonApi(f, gossipsubHeartbeatInterval = 100,
                              gossipsubHeartbeatDelay = 100)
  else:
    api1 = await newDaemonApi(f)
    api2 = await newDaemonApi(f)

  var id1 = await api1.identity()
  var id2 = await api2.identity()

  var resultsCount = 0

  var topics10 = await api1.pubsubGetTopics()
  var peers10 = await api1.pubsubListPeers("test-topic")
  var topics20 = await api2.pubsubGetTopics()
  var peers20 = await api2.pubsubListPeers("test-topic")

  var handlerFuture1 = newFuture[void]()
  var handlerFuture2 = newFuture[void]()

  proc pubsubHandler1(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} =
    echo "handler1"
    let smsg = cast[string](message.data)
    if smsg == pubsubData:
      inc(resultsCount)
    handlerFuture1.complete()
    # Callback must return `false` to close subscription channel.
    result = false

  proc pubsubHandler2(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} =
    echo "handler2"
    let smsg = cast[string](message.data)
    if smsg == pubsubData:
      inc(resultsCount)
    handlerFuture2.complete()
    # Callback must return `false` to close subscription channel.
    result = false

  if len(topics10) == 0 and len(peers10) == 0 and
     len(topics20) == 0 and len(peers20) == 0:
    # Not subscribed to any topics everything must be 0.

    await api1.connect(id2.peer, id2.addresses)
    await api2.connect(id1.peer, id1.addresses)

    var gpeers1 = await api1.listPeers()
    var gpeers2 = await api2.listPeers()
    echo "globalPeers1 = ", gpeers1
    echo "globalPeers2 = ", gpeers2

    var ticket1 = await api1.pubsubSubscribe("test-topic", pubsubHandler1)
    var ticket2 = await api2.pubsubSubscribe("test-topic", pubsubHandler2)

    var topics1 = await api1.pubsubGetTopics()
    var topics2 = await api2.pubsubGetTopics()

    if len(topics1) == 1 and len(topics2) == 1:
      echo "connecting"

      while true:
        var peers1 = await api1.pubsubListPeers("test-topic")
        var peers2 = await api2.pubsubListPeers("test-topic")
        if len(peers1) == 1 and len(peers2) == 1:
          break
        echo "pubsubPeers1 = ", peers1
        echo "pubsubPeers2 = ", peers2
        # var gpeers1 = await api1.listPeers()
        # var gpeers2 = await api2.listPeers()
        # echo "globalPeers1 = ", gpeers1
        # echo "globalPeers2 = ", gpeers2
        await sleepAsync(500)
      

      # if len(topics12) == 1 and len(peers12) == 1 and
      #    len(topics22) == 1 and len(peers22) == 1:
      echo "Publishing"
      # Publish test data via api1.
      await sleepAsync(500)
      await api1.pubsubPublish("test-topic", msgData)
      var andfut = handlerFuture1 and handlerFuture2
      await andfut or sleepAsync(10000)
        
  await api1.close()
  await api2.close()
  if resultsCount == 2:
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
    test "GossipSub test":
      check:
        waitFor(pubsubTest({PSGossipSub})) == true
    test "FloodSub test":
      check:
        waitFor(pubsubTest({PSFloodSub})) == true

