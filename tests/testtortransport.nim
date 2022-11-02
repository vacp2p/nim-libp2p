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

    let serverSwitch = TorSwitch.new(torServer, rng, @[ma], {ReuseAddr})

    # setup the custom proto
    let testProto = TestProto.new()

    serverSwitch.mount(testProto)
    await serverSwitch.start()

    let serverPeerId = serverSwitch.peerInfo.peerId
    let serverAddress = serverSwitch.peerInfo.addrs

    proc startClient() {.async.} =
      let clientSwitch = TorSwitch.new(torServer = torServer, rng= rng, flags = {ReuseAddr})

      let conn = await clientSwitch.dial(serverPeerId, serverAddress, TestCodec)

      await conn.write("client")

      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "server"
      await conn.close()
      await clientSwitch.stop()

    await startClient()

    await serverSwitch.stop()

  test "It's not possible to add another transport in TorSwitch":
    when (NimMajor, NimMinor, NimPatch) < (1, 4, 0):
      type AssertionDefect = AssertionError

    let torSwitch = TorSwitch.new(torServer = torServer, rng= rng, flags = {ReuseAddr})
    expect(AssertionDefect):
      torSwitch.addTransport(TcpTransport.new(upgrade = Upgrade()))
    waitFor torSwitch.stop()

  proc transProvider(): Transport =
      TorTransport.new(torServer, {ReuseAddr}, Upgrade())


  commonTransportTest(
    transProvider,
    "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80",
    "/ip4/127.0.0.1/tcp/8081/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae:80")
