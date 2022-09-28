{.used.}

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

import ./helpers, ./commontransport

const torServer = initTAddress("127.0.0.1", 9050.Port)

type
  TorServerStub = ref object of RootObj
    tcpTransport: TcpTransport
    addrTable: Table[string, string]

proc new(
  T: typedesc[TorServerStub]): T {.public.} =

  T(
    tcpTransport: TcpTransport.new(flags = {ReuseAddr}, upgrade = Upgrade()),
    addrTable: initTable[string, string]())

proc registerOnionAddr(self: TorServerStub, key: string, val: string) =
  self.addrTable[key] = val

proc start(self: TorServerStub) {.async, raises: [].} =
  let ma = @[MultiAddress.init(torServer).tryGet()]

  await self.tcpTransport.start(ma)

  var msg = newSeq[byte](3)

  let connSrc = await self.tcpTransport.accept()
  await connSrc.readExactly(addr msg[0], 3)

  await connSrc.write(@[05'u8, 00])

  msg = newSeq[byte](5)
  await connSrc.readExactly(addr msg[0], 5)
  let n = int(uint8.fromBytes(msg[4..4])) + 2 # +2 bytes for the port
  msg = newSeq[byte](n)
  await connSrc.readExactly(addr msg[0], n)

  let onionAddr = string.fromBytes(msg[0..^3]) # ignore the port

  let tcpIpAddr = self.addrTable[$(onionAddr)]

  await connSrc.write(@[05'u8, 00, 00, 01, 00, 00, 00, 00, 00, 00])

  let connDst = await self.tcpTransport.dial("", MultiAddress.init(tcpIpAddr).tryGet())

  await bridge(connSrc, connDst)

proc stop(self: TorServerStub) {.async, raises: [].} =
  await self.tcpTransport.stop()

suite "Tor transport":
  teardown:
    checkTrackers()

  asyncTest "test dial and start":

    proc startClient() {.async, raises:[].} =
      let s = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
      let ma = MultiAddress.init("/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80")
      let conn = await s.dial("", ma.tryGet())

      await conn.write("client")
      var resp: array[6, byte]
      discard await conn.readOnce(addr resp, 6)
      await conn.close()

      check string.fromBytes(resp) == "server"

    let server = TorTransport.new(torServer, {ReuseAddr}, Upgrade())
    let ma2 = @[MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()]
    await server.start(ma2)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await server.accept()

      var resp: array[6, byte]
      discard await conn.readOnce(addr resp, 6)
      check string.fromBytes(resp) == "client"

      await conn.write("server")
      await conn.close()

    let stub = TorServerStub.new()
    stub.registerOnionAddr("a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion", "/ip4/127.0.0.1/tcp/8080")

    asyncSpawn stub.start()

    asyncSpawn acceptHandler()

    await startClient()

    await allFutures(server.stop(), stub.stop())


  asyncTest "test dial and start with builder":

    ##
    # Create our custom protocol
    ##
    const TestCodec = "/test/proto/1.0.0" # custom protocol string identifier

    type
      TestProto = ref object of LPProtocol # declare a custom protocol

    proc new(T: typedesc[TestProto]): T =

      # every incoming connections will be in handled in this closure
      proc handle(conn: Connection, proto: string) {.async, gcsafe.} =

        var resp: array[6, byte]
        discard await conn.readOnce(addr resp, 6)
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

    proc startClient() {.async, raises:[].} =
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

    let stub = TorServerStub.new()
    stub.registerOnionAddr("a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion", "/ip4/127.0.0.1/tcp/8080")
    asyncSpawn stub.start()

    await startClient()

    await allFutures(serverSwitch.stop(), stub.stop())


