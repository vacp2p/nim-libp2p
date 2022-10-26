{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import tables
import chronos, stew/[byteutils, endians2]
import ../libp2p/[stream/connection,
                  protocols/connectivity/relay/utils,
                  transports/tcptransport,
                  transports/tortransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  builders]

import ./helpers, ./stubs, ./commontransport

const torServer = initTAddress("127.0.0.1", 9050.Port)
var stub: TorServerStub
var startFut: Future[void]
suite "Tor transport":
  setup:
    stub = TorServerStub.new()
    stub.registerOnionAddr("a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion", "/ip4/127.0.0.1/tcp/8080")
    stub.registerOnionAddr("a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae.onion", "/ip4/127.0.0.1/tcp/8081")
    startFut = stub.start()
  teardown:
    waitFor startFut.cancelAndWait()
    waitFor stub.stop()
    checkTrackers()

  asyncTest "test dial and start":
    let server = TorTransport.new(torServer, {ReuseAddr}, Upgrade())
    let ma2 = @[MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()]
    await server.start(ma2)

    proc runClient() {.async.} =
      let client = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
      let conn = await client.dial("", server.addrs[0])

      await conn.write("client")
      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      await conn.close()

      check string.fromBytes(resp) == "server"
      await client.stop()

    proc serverAcceptHandler() {.async, gcsafe.} =
      let conn = await server.accept()

      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "client"

      await conn.write("server")
      await conn.close()
      await server.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()

  asyncTest "test dial and start with builder":
    const TestCodec = "/test/proto/1.0.0" # custom protocol string identifier

    type
      TestProto = ref object of LPProtocol # declare a custom protocol

    proc new(T: typedesc[TestProto]): T =

      # every incoming connections will be in handled in this closure
      proc handle(conn: Connection, proto: string) {.async, gcsafe.} =

        var resp: array[6, byte]
        await conn.readExactly(addr resp, 6)
        check string.fromBytes(resp) == "client"
        await conn.write("server")

        # We must close the connections ourselves when we're done with it
        await conn.close()

      return T(codecs: @[TestCodec], handler: handle)

    let rng = newRng()

    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()

    let serverSwitch = SwitchBuilder.new()
      .withRng(rng)
      .withTorTransport(torServer, {ReuseAddr})
      .withAddress(ma)
      .withMplex()
      .withNoise()
      .build()

    # setup the custom proto
    let testProto = TestProto.new()

    serverSwitch.mount(testProto)
    await serverSwitch.start()

    let serverPeerId = serverSwitch.peerInfo.peerId
    let serverAddress = serverSwitch.peerInfo.addrs

    proc startClient() {.async.} =
      let clientSwitch = SwitchBuilder.new()
        .withRng(rng)
        .withTorTransport(torServer)
        .withMplex()
        .withNoise()
        .build()

      let conn = await clientSwitch.dial(serverPeerId, serverAddress, TestCodec)

      await conn.write("client")

      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "server"
      await conn.close()
      await clientSwitch.stop()

    await startClient()

    await serverSwitch.stop()

  proc transProvider(): Transport = TorTransport.new(transportAddress = torServer, flags = {ReuseAddr}, upgrade = Upgrade())

  commonTransportTest(
    transProvider,
    "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80",
    "/ip4/127.0.0.1/tcp/8081/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae:80")


