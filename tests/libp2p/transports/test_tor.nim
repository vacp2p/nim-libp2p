# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}
{.push raises: [].}

import tables, chronos, stew/[byteutils]
import
  ../../../libp2p/[
    stream/connection,
    transports/transport,
    transports/tortransport,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    muxers/muxer,
    muxers/mplex/mplex,
    builders,
  ]
import ../../tools/[unittest, crypto]
import ../../stubs/torstub
import ./basic_tests
import ./connection_tests
import ./stream_tests

suite "Tor transport":
  const torServer = initTAddress("127.0.0.1", 9050.Port)
  var stub: TorServerStub
  var startFut: Future[void]

  proc torTransProvider(): Transport =
    TorTransport.new(torServer, {ReuseAddr}, Upgrade())

  proc streamProvider(conn: Connection, handle: bool = true): Muxer =
    let muxer = Mplex.new(conn)
    if handle:
      asyncSpawn muxer.handle()
    muxer

  const
    address =
      "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80"
    address2 =
      "/ip4/127.0.0.1/tcp/8081/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae:81"
    validAddresses =
      @[
        # Addresses for dialing
        "/ip4/127.0.0.1/tcp/1234", # TCP
        "/ip6/::1/tcp/1234", # TCP over IPv6
        "/dns/example.com/tcp/1234", # TCP with DNS
        "/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80", # Onion3
        # Addresses for listening (TcpOnion3)
        "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80",
        "/ip6/::1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80",
      ]
    invalidAddresses =
      @[
        "/ip4/127.0.0.1/udp/1234", # UDP not supported
        "/ip4/127.0.0.1/tcp/1234/ws", # WebSocket not supported
        "/ip4/127.0.0.1/tcp/1234/quic-v1", # QUIC not supported
        "/ip4/127.0.0.1/tcp/1234/wss", # WSS not supported
      ]

  setup:
    stub = TorServerStub.new()
    stub.registerAddr("127.0.0.1:8080", "/ip4/127.0.0.1/tcp/8080")
    stub.registerAddr("libp2p.nim:8080", "/ip4/127.0.0.1/tcp/8080")
    stub.registerAddr("::1:8080", "/ip6/::1/tcp/8080")
    stub.registerAddr(
      "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion:80",
      "/ip4/127.0.0.1/tcp/8080",
    )
    stub.registerAddr(
      "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae.onion:81",
      "/ip4/127.0.0.1/tcp/8081",
    )
    startFut = stub.start(torServer)

  teardown:
    waitFor startFut.cancelAndWait()
    waitFor stub.stop()
    checkTrackers()

  basicTransportTest(torTransProvider, address, validAddresses, invalidAddresses)
  connectionTransportTest(torTransProvider, address, address2)
  streamTransportTest(
    torTransProvider,
    MultiAddress.init(address).get(),
    Opt.none(MultiAddress),
    streamProvider,
  )

  proc test(lintesAddr: string, dialAddr: string) {.async.} =
    let server = TcpTransport.new({ReuseAddr}, Upgrade())
    let ma2 = @[MultiAddress.init(lintesAddr).tryGet()]
    await server.start(ma2)

    proc runClient() {.async.} =
      let client = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
      let conn = await client.dial("", MultiAddress.init(dialAddr).tryGet())

      await conn.write("client")
      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      await conn.close()

      check string.fromBytes(resp) == "server"
      await client.stop()

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      var resp: array[6, byte]
      await conn.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "client"

      await conn.write("server")
      await conn.close()
      await server.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()

  asyncTest "test start and dial using ipv4":
    await test("/ip4/127.0.0.1/tcp/8080", "/ip4/127.0.0.1/tcp/8080")

  asyncTest "test start and dial using ipv6":
    await test("/ip6/::1/tcp/8080", "/ip6/::1/tcp/8080")

  asyncTest "test start and dial using dns":
    await test("/ip4/127.0.0.1/tcp/8080", "/dns/libp2p.nim/tcp/8080")

  asyncTest "test start and dial usion onion3 and builder":
    const TestCodec = "/test/proto/1.0.0" # custom protocol string identifier

    type TestProto = ref object of LPProtocol # declare a custom protocol

    proc new(T: typedesc[TestProto]): T =
      # every incoming connections will be in handled in this closure
      proc handle(
          conn: Connection, proto: string
      ) {.async: (raises: [CancelledError]).} =
        try:
          var resp: array[6, byte]
          await conn.readExactly(addr resp, 6)
          check string.fromBytes(resp) == "client"
          await conn.write("server")
        except LPStreamError:
          raiseAssert "Unexpected LPStreamError in Tor onion3 test handler"
        finally:
          await conn.close()

      return T.new(codecs = @[TestCodec], handler = handle)

    let ma = MultiAddress
      .init(
        "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80"
      )
      .tryGet()

    let serverSwitch = TorSwitch.new(torServer, rng, @[ma], {ReuseAddr})

    # setup the custom proto
    let testProto = TestProto.new()

    serverSwitch.mount(testProto)
    await serverSwitch.start()

    let serverPeerId = serverSwitch.peerInfo.peerId
    let serverAddress = serverSwitch.peerInfo.addrs

    proc startClient() {.async.} =
      let clientSwitch =
        TorSwitch.new(torServer = torServer, rng = rng, flags = {ReuseAddr})

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
    let torSwitch = TorSwitch.new(torServer = torServer, rng = rng, flags = {ReuseAddr})
    expect(AssertionDefect):
      torSwitch.addTransport(TcpTransport.new(upgrade = Upgrade()))
    waitFor torSwitch.stop()
