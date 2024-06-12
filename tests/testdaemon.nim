import chronos, unittest2, helpers
import
  ../libp2p/daemon/daemonapi,
  ../libp2p/multiaddress,
  ../libp2p/multicodec,
  ../libp2p/cid,
  ../libp2p/multihash,
  ../libp2p/peerid

when defined(nimHasUsed):
  {.used.}

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
  # echo await api1.listPeers()
  var stream = await api1.openStream(id2.peer, protos)
  let sent = await stream.transp.write(test & "\r\n")
  doAssert(sent == len(test) + 2)
  doAssert((await wait(testFuture, 10.seconds)) == test)
  await stream.close()
  await api1.close()
  await api2.close()
  result = true

proc pubsubTest(f: set[P2PDaemonFlags]): Future[bool] {.async.} =
  var pubsubData = "TEST MESSAGE"
  var msgData = cast[seq[byte]](pubsubData)
  var api1, api2: DaemonAPI

  api1 = await newDaemonApi(f)
  api2 = await newDaemonApi(f)

  var id1 = await api1.identity()
  var id2 = await api2.identity()

  var resultsCount = 0

  var handlerFuture1 = newFuture[void]()
  var handlerFuture2 = newFuture[void]()

  proc pubsubHandler1(
      api: DaemonAPI, ticket: PubsubTicket, message: PubSubMessage
  ): Future[bool] {.async.} =
    let smsg = cast[string](message.data)
    if smsg == pubsubData:
      inc(resultsCount)
    handlerFuture1.complete()
    # Callback must return `false` to close subscription channel.
    result = false

  proc pubsubHandler2(
      api: DaemonAPI, ticket: PubsubTicket, message: PubSubMessage
  ): Future[bool] {.async.} =
    let smsg = cast[string](message.data)
    if smsg == pubsubData:
      inc(resultsCount)
    handlerFuture2.complete()
    # Callback must return `false` to close subscription channel.
    result = false

  await api1.connect(id2.peer, id2.addresses)
  await api2.connect(id1.peer, id1.addresses)

  var ticket1 = await api1.pubsubSubscribe("test-topic", pubsubHandler1)
  var ticket2 = await api2.pubsubSubscribe("test-topic", pubsubHandler2)

  await sleepAsync(2.seconds)

  var topics1 = await api1.pubsubGetTopics()
  var topics2 = await api2.pubsubGetTopics()

  if len(topics1) == 1 and len(topics2) == 1:
    var peers1 = await api1.pubsubListPeers("test-topic")
    var peers2 = await api2.pubsubListPeers("test-topic")
    if len(peers1) == 1 and len(peers2) == 1:
      # Publish test data via api1.
      await sleepAsync(500.milliseconds)
      await api1.pubsubPublish("test-topic", msgData)
      var res =
        await one(allFutures(handlerFuture1, handlerFuture2), sleepAsync(10.seconds))

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
    flakyAsyncTest "GossipSub test", attempts = 4:
      check (await pubsubTest({PSGossipSub})) == true
    flakyAsyncTest "FloodSub test", attempts = 4:
      check (await pubsubTest({PSFloodSub})) == true
