import options, tables
import chronos, chronicles, stew/byteutils
import helpers
import ../libp2p
import ../libp2p/[daemon/daemonapi, varint, transports/wstransport, crypto/crypto]
import ../libp2p/protocols/connectivity/relay/[relay, client, utils]

type
  SwitchCreator = proc(
    ma: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    prov: TransportProvider = proc(upgr: Upgrade): Transport = TcpTransport.new({}, upgr),
    relay: Relay = Relay.new(circuitRelayV1 = true)):
       Switch {.gcsafe, raises: [LPError].}
  DaemonPeerInfo = daemonapi.PeerInfo

proc writeLp(s: StreamTransport, msg: string | seq[byte]): Future[int] {.gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  result = s.write(buf.buffer)

proc readLp(s: StreamTransport): Future[seq[byte]] {.async.} =
  ## read length prefixed msg
  var
    size: uint
    length: int
    res: VarintResult[void]
  result = newSeq[byte](10)

  for i in 0..<len(result):
    await s.readExactly(addr result[i], 1)
    res = LP.getUVarint(result.toOpenArray(0, i), length, size)
    if res.isOk():
      break
  res.expect("Valid varint")
  result.setLen(size)
  if size > 0.uint:
    await s.readExactly(addr result[0], int(size))

proc testPubSubDaemonPublish(
    gossip: bool = false,
    count: int = 1,
    swCreator: SwitchCreator) {.async.} =
  var pubsubData = "TEST MESSAGE"
  var testTopic = "test-topic"
  var msgData = pubsubData.toBytes()

  var flags = {PSFloodSub}
  if gossip:
    flags = {PSGossipSub}

  let daemonNode = await newDaemonApi(flags)
  let daemonPeer = await daemonNode.identity()
  let nativeNode = swCreator()

  let pubsub = if gossip:
      GossipSub.init(
        switch = nativeNode).PubSub
    else:
      FloodSub.init(
        switch = nativeNode).PubSub

  nativeNode.mount(pubsub)

  await nativeNode.start()
  await pubsub.start()
  let nativePeer = nativeNode.peerInfo

  var finished = false
  var times = 0
  proc nativeHandler(topic: string, data: seq[byte]) {.async.} =
    let smsg = string.fromBytes(data)
    check smsg == pubsubData
    times.inc()
    if times >= count and not finished:
      finished = true

  await nativeNode.connect(daemonPeer.peer, daemonPeer.addresses)

  await sleepAsync(1.seconds)
  await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)

  proc pubsubHandler(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} =
    result = true # don't cancel subscription

  asyncDiscard daemonNode.pubsubSubscribe(testTopic, pubsubHandler)
  pubsub.subscribe(testTopic, nativeHandler)
  await sleepAsync(5.seconds)

  proc publisher() {.async.} =
    while not finished:
      await daemonNode.pubsubPublish(testTopic, msgData)
      await sleepAsync(500.millis)

  await wait(publisher(), 5.minutes) # should be plenty of time

  await nativeNode.stop()
  await pubsub.stop()
  await daemonNode.close()

proc testPubSubNodePublish(
    gossip: bool = false,
    count: int = 1,
    swCreator: SwitchCreator) {.async.} =
  var pubsubData = "TEST MESSAGE"
  var testTopic = "test-topic"
  var msgData = pubsubData.toBytes()

  var flags = {PSFloodSub}
  if gossip:
    flags = {PSGossipSub}

  let daemonNode = await newDaemonApi(flags)
  let daemonPeer = await daemonNode.identity()
  let nativeNode = swCreator()

  let pubsub = if gossip:
      GossipSub.init(
        switch = nativeNode).PubSub
    else:
      FloodSub.init(
        switch = nativeNode).PubSub

  nativeNode.mount(pubsub)

  await nativeNode.start()
  await pubsub.start()
  let nativePeer = nativeNode.peerInfo

  await nativeNode.connect(daemonPeer.peer, daemonPeer.addresses)

  await sleepAsync(1.seconds)
  await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)

  var times = 0
  var finished = false
  proc pubsubHandler(api: DaemonAPI,
                     ticket: PubsubTicket,
                     message: PubSubMessage): Future[bool] {.async.} =
    let smsg = string.fromBytes(message.data)
    check smsg == pubsubData
    times.inc()
    if times >= count and not finished:
      finished = true
    result = true # don't cancel subscription

  discard await daemonNode.pubsubSubscribe(testTopic, pubsubHandler)
  proc nativeHandler(topic: string, data: seq[byte]) {.async.} = discard
  pubsub.subscribe(testTopic, nativeHandler)
  await sleepAsync(5.seconds)

  proc publisher() {.async.} =
    while not finished:
      discard await pubsub.publish(testTopic, msgData)
      await sleepAsync(500.millis)

  await wait(publisher(), 5.minutes) # should be plenty of time

  check finished
  await nativeNode.stop()
  await pubsub.stop()
  await daemonNode.close()

proc commonInteropTests*(name: string, swCreator: SwitchCreator) =
  suite "Interop using " & name:
    # TODO: chronos transports are leaking,
    # but those are tracked for both the daemon
    # and libp2p, so not sure which one it is,
    # need to investigate more
    # teardown:
    #   checkTrackers()

    # TODO: this test is failing sometimes on windows
    # For some reason we receive EOF before test 4 sometimes

    asyncTest "native -> daemon multiple reads and writes":
      var protos = @["/test-stream"]

      let nativeNode = swCreator()

      await nativeNode.start()
      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()

      var testFuture = newFuture[void]("test.future")
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        check string.fromBytes(await stream.transp.readLp()) == "test 1"
        discard await stream.transp.writeLp("test 2")
        check string.fromBytes(await stream.transp.readLp()) == "test 3"
        discard await stream.transp.writeLp("test 4")
        testFuture.complete()

      await daemonNode.addHandler(protos, daemonHandler)
      let conn = await nativeNode.dial(daemonPeer.peer, daemonPeer.addresses, protos[0])
      await conn.writeLp("test 1")
      check "test 2" == string.fromBytes((await conn.readLp(1024)))

      await conn.writeLp("test 3")
      check "test 4" == string.fromBytes((await conn.readLp(1024)))

      await wait(testFuture, 10.secs)

      await nativeNode.stop()
      await daemonNode.close()

      await sleepAsync(1.seconds)

    asyncTest "native -> daemon connection":
      var protos = @["/test-stream"]
      var test = "TEST STRING"
      # We are preparing expect string, which should be prefixed with varint
      # length and do not have `\r\n` suffix, because we going to use
      # readLine().
      var buffer = initVBuffer()
      buffer.writeSeq(test & "\r\n")
      buffer.finish()
      var expect = newString(len(buffer) - 2)
      copyMem(addr expect[0], addr buffer.buffer[0], len(expect))

      let nativeNode = swCreator()

      await nativeNode.start()

      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()

      var testFuture = newFuture[string]("test.future")
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        # We should perform `readLp()` instead of `readLine()`. `readLine()`
        # here reads actually length prefixed string.
        var line = await stream.transp.readLine()
        check line == expect
        testFuture.complete(line)
        await stream.close()

      await daemonNode.addHandler(protos, daemonHandler)
      let conn = await nativeNode.dial(daemonPeer.peer, daemonPeer.addresses, protos[0])
      await conn.writeLp(test & "\r\n")
      check expect == (await wait(testFuture, 10.secs))

      await conn.close()
      await nativeNode.stop()
      await daemonNode.close()

    asyncTest "daemon -> native connection":
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      var testFuture = newFuture[string]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        var line = string.fromBytes(await conn.readLp(1024))
        check line == test
        testFuture.complete(line)
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = swCreator()

      nativeNode.mount(proto)

      await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)
      discard await stream.transp.writeLp(test)

      check test == (await wait(testFuture, 10.secs))

      await stream.close()
      await nativeNode.stop()
      await daemonNode.close()
      await sleepAsync(1.seconds)

    asyncTest "native -> daemon websocket connection":
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      var testFuture = newFuture[string]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        var line = string.fromBytes(await conn.readLp(1024))
        check line == test
        testFuture.complete(line)
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let wsAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()

      let nativeNode = swCreator(
        ma = wsAddress,
        prov = proc (upgr: Upgrade): Transport = WsTransport.new(upgr)
      )

      nativeNode.mount(proto)

      await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi(hostAddresses = @[wsAddress])
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)
      discard await stream.transp.writeLp(test)

      check test == (await wait(testFuture, 10.secs))

      await stream.close()
      await nativeNode.stop()
      await daemonNode.close()
      await sleepAsync(1.seconds)

    asyncTest "daemon -> native websocket connection":
      var protos = @["/test-stream"]
      var test = "TEST STRING"
      # We are preparing expect string, which should be prefixed with varint
      # length and do not have `\r\n` suffix, because we going to use
      # readLine().
      var buffer = initVBuffer()
      buffer.writeSeq(test & "\r\n")
      buffer.finish()
      var expect = newString(len(buffer) - 2)
      copyMem(addr expect[0], addr buffer.buffer[0], len(expect))

      let wsAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()
      let nativeNode = SwitchBuilder
        .new()
        .withAddress(wsAddress)
        .withRng(crypto.newRng())
        .withMplex()
        .withTransport(proc (upgr: Upgrade): Transport = WsTransport.new(upgr))
        .withNoise()
        .build()

      await nativeNode.start()

      let daemonNode = await newDaemonApi(hostAddresses = @[wsAddress])
      let daemonPeer = await daemonNode.identity()

      var testFuture = newFuture[string]("test.future")
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        # We should perform `readLp()` instead of `readLine()`. `readLine()`
        # here reads actually length prefixed string.
        var line = await stream.transp.readLine()
        check line == expect
        testFuture.complete(line)
        await stream.close()

      await daemonNode.addHandler(protos, daemonHandler)
      let conn = await nativeNode.dial(daemonPeer.peer, daemonPeer.addresses, protos[0])
      await conn.writeLp(test & "\r\n")
      check expect == (await wait(testFuture, 10.secs))

      await conn.close()
      await nativeNode.stop()
      await daemonNode.close()

    asyncTest "daemon -> multiple reads and writes":
      var protos = @["/test-stream"]

      var testFuture = newFuture[void]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        check "test 1" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test 2".toBytes())

        check "test 3" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test 4".toBytes())

        testFuture.complete()
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = swCreator()

      nativeNode.mount(proto)

      await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)

      asyncDiscard stream.transp.writeLp("test 1")
      check "test 2" == string.fromBytes(await stream.transp.readLp())

      asyncDiscard stream.transp.writeLp("test 3")
      check "test 4" == string.fromBytes(await stream.transp.readLp())

      await wait(testFuture, 10.secs)

      await stream.close()
      await nativeNode.stop()
      await daemonNode.close()

    asyncTest "read write multiple":
      var protos = @["/test-stream"]
      var test = "TEST STRING"

      var count = 0
      var testFuture = newFuture[int]("test.future")
      proc nativeHandler(conn: Connection, proto: string) {.async.} =
        while count < 10:
          var line = string.fromBytes(await conn.readLp(1024))
          check line == test
          await conn.writeLp(test.toBytes())
          count.inc()

        testFuture.complete(count)
        await conn.close()

      # custom proto
      var proto = new LPProtocol
      proto.handler = nativeHandler
      proto.codec = protos[0] # codec

      let nativeNode = swCreator()

      nativeNode.mount(proto)

      await nativeNode.start()
      let nativePeer = nativeNode.peerInfo

      let daemonNode = await newDaemonApi()
      await daemonNode.connect(nativePeer.peerId, nativePeer.addrs)
      var stream = await daemonNode.openStream(nativePeer.peerId, protos)

      var count2 = 0
      while count2 < 10:
        discard await stream.transp.writeLp(test)
        let line = await stream.transp.readLp()
        check test == string.fromBytes(line)
        inc(count2)

      check 10 == (await wait(testFuture, 1.minutes))
      await stream.close()
      await nativeNode.stop()
      await daemonNode.close()

    asyncTest "floodsub: daemon publish one":
      await testPubSubDaemonPublish(swCreator = swCreator)

    asyncTest "floodsub: daemon publish many":
      await testPubSubDaemonPublish(count = 10, swCreator = swCreator)

    asyncTest "gossipsub: daemon publish one":
      await testPubSubDaemonPublish(gossip = true, swCreator = swCreator)

    asyncTest "gossipsub: daemon publish many":
      await testPubSubDaemonPublish(gossip = true, count = 10, swCreator = swCreator)

    asyncTest "floodsub: node publish one":
      await testPubSubNodePublish(swCreator = swCreator)

    asyncTest "floodsub: node publish many":
      await testPubSubNodePublish(count = 10, swCreator = swCreator)

    asyncTest "gossipsub: node publish one":
      await testPubSubNodePublish(gossip = true, swCreator = swCreator)

    asyncTest "gossipsub: node publish many":
      await testPubSubNodePublish(gossip = true, count = 10, swCreator = swCreator)

proc relayInteropTests*(name: string, relayCreator: SwitchCreator) =
  suite "Interop relay using " & name:
    asyncTest "NativeSrc -> NativeRelay -> DaemonDst":
      let closeBlocker = newFuture[void]()
      # TODO: This Future blocks the daemonHandler after sending the last message.
      # It exists because there's a strange behavior where stream.close sends
      # a Rst instead of Fin. We should investigate this at some point.
      proc daemonHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        check "line1" == string.fromBytes(await stream.transp.readLp())
        discard await stream.transp.writeLp("line2")
        check "line3" == string.fromBytes(await stream.transp.readLp())
        discard await stream.transp.writeLp("line4")
        await closeBlocker
        await stream.close()
      let
        maSrc = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        maRel = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        src = relayCreator(maSrc, relay = RelayClient.new(circuitRelayV1 = true))
        rel = relayCreator(maRel)

      await src.start()
      await rel.start()
      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()
      let maStr = $rel.peerInfo.addrs[0] & "/p2p/" & $rel.peerInfo.peerId & "/p2p-circuit"
      let maddr = MultiAddress.init(maStr).tryGet()
      await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await rel.connect(daemonPeer.peer, daemonPeer.addresses)

      await daemonNode.addHandler(@[ "/testCustom" ], daemonHandler)

      let conn = await src.dial(daemonPeer.peer, @[ maddr ], @[ "/testCustom" ])

      await conn.writeLp("line1")
      check string.fromBytes(await conn.readLp(1024)) == "line2"

      await conn.writeLp("line3")
      check string.fromBytes(await conn.readLp(1024)) == "line4"

      closeBlocker.complete()
      await allFutures(src.stop(), rel.stop())
      await daemonNode.close()

    asyncTest "DaemonSrc -> NativeRelay -> NativeDst":
      proc customHandler(conn: Connection, proto: string) {.async.} =
        check "line1" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("line2")
        check "line3" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("line4")
        await conn.close()
      let
        protos = @[ "/customProto", RelayV1Codec ]
      var
        customProto = new LPProtocol
      customProto.handler = customHandler
      customProto.codec = protos[0]
      let
        maRel = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        maDst = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        rel = relayCreator(maRel)
        dst = relayCreator(maDst, relay=RelayClient.new())

      dst.mount(customProto)
      await rel.start()
      await dst.start()
      let daemonNode = await newDaemonApi()
      let daemonPeer = await daemonNode.identity()
      let maStr = $rel.peerInfo.addrs[0] & "/p2p/" & $rel.peerInfo.peerId & "/p2p-circuit"
      let maddr = MultiAddress.init(maStr).tryGet()
      await daemonNode.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await rel.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
      await daemonNode.connect(dst.peerInfo.peerId, @[ maddr ])
      var stream = await daemonNode.openStream(dst.peerInfo.peerId, protos)

      discard await stream.transp.writeLp("line1")
      check string.fromBytes(await stream.transp.readLp()) == "line2"
      discard await stream.transp.writeLp("line3")
      check string.fromBytes(await stream.transp.readLp()) == "line4"

      await allFutures(dst.stop(), rel.stop())
      await daemonNode.close()

    asyncTest "NativeSrc -> DaemonRelay -> NativeDst":
      proc customHandler(conn: Connection, proto: string) {.async.} =
        check "line1" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("line2")
        check "line3" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("line4")
        await conn.close()
      let
        protos = @[ "/customProto", RelayV1Codec ]
      var
        customProto = new LPProtocol
      customProto.handler = customHandler
      customProto.codec = protos[0]
      let
        maSrc = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        maDst = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        src = relayCreator(maSrc, relay=RelayClient.new())
        dst = relayCreator(maDst, relay=RelayClient.new())

      dst.mount(customProto)
      await src.start()
      await dst.start()
      let daemonNode = await newDaemonApi({RelayHop})
      let daemonPeer = await daemonNode.identity()
      let maStr = $daemonPeer.addresses[0] & "/p2p/" & $daemonPeer.peer & "/p2p-circuit"
      let maddr = MultiAddress.init(maStr).tryGet()
      await src.connect(daemonPeer.peer, daemonPeer.addresses)
      await daemonNode.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
      let conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

      await conn.writeLp("line1")
      check string.fromBytes(await conn.readLp(1024)) == "line2"

      await conn.writeLp("line3")
      check string.fromBytes(await conn.readLp(1024)) == "line4"

      await allFutures(src.stop(), dst.stop())
      await daemonNode.close()
