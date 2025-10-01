{.used.}

# Nim-Libp2p
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import tables
import chronos, stew/[byteutils]
import
  ../libp2p/[
    stream/connection,
    transports/tcptransport,
    transports/tortransport,
    transports/transport,
    transports/memorytransport,
    transports/quictransport,
    transports/wstransport,
    upgrademngrs/upgrade,
    multiaddress,
    builders,
    crypto/crypto,
  ]

import ./helpers, ./stubs/torstub, ./commontransport

const torServer = initTAddress("127.0.0.1", 9050.Port)
var stub: TorServerStub
var startFut: Future[void]
suite "Tor transport":
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
        except CancelledError as e:
          raise e
        except CatchableError:
          check false # should not be here
        finally:
          await conn.close()

      return T.new(codecs = @[TestCodec], handler = handle)

    let rng = newRng()

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

  proc transProvider(): Transport =
    TorTransport.new(torServer, {ReuseAddr}, Upgrade())

  commonTransportTest(
    transProvider,
    "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80",
    "/ip4/127.0.0.1/tcp/8081/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcae:81",
  )

proc testTransportEvents(transport: Transport, addrs: seq[MultiAddress]) {.async.} =
  ## Common test procedure for transport events
  var onRunningFired = false
  var onStopFired = false

  proc onRunningHandler() {.async.} =
    # onRunning only gets set during start() call
    await transport.onRunning.wait()
    onRunningFired = true

  proc onStopHandler() {.async.} =
    # onStop only gets set during stop() call
    await transport.onStop.wait()
    onStopFired = true

  asyncSpawn onRunningHandler()
  asyncSpawn onStopHandler()

  check:
    onRunningFired == false
    onStopFired == false
    transport.running == false

  await transport.start(addrs)

  # Give the event handler time to run
  await sleepAsync(10.milliseconds)

  check:
    onRunningFired == true
    onStopFired == false
    transport.running == true

  await transport.stop()

  # Give the event handler time to run
  await sleepAsync(10.milliseconds)

  check:
    onRunningFired == true
    onStopFired == true
    transport.running == false

suite "Transport Events":
  asyncTest "onRunning with TCP transport":
    let transport = TcpTransport.new(upgrade = Upgrade())
    await testTransportEvents(
      transport, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()]
    )

  asyncTest "onRunning event can be awaited":
    let transport = TcpTransport.new(upgrade = Upgrade())

    let startFut =
      transport.start(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await transport.onRunning.wait()

    check:
      transport.running == true

    await startFut
    await transport.stop()

  asyncTest "onRunning with transports":
    await testTransportEvents(MemoryTransport.new(upgrade = Upgrade()), @[])
    await testTransportEvents(
      WsTransport.new(Upgrade()),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()],
    )
    await testTransportEvents(
      QuicTransport.new(Upgrade(), PrivateKey.random(ECDSA, (newRng())[]).tryGet()),
      @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()],
    )

  asyncTest "onRunning with Tor transport":
    # Setup Tor stub server
    let addrs = initTAddress("127.0.0.1", 9050.Port)
    let stub = TorServerStub.new()
    stub.registerAddr(
      "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion:80",
      "/ip4/127.0.0.1/tcp/8080",
    )
    let startFut = stub.start(addrs)

    await sleepAsync(100.milliseconds)

    # Use a proper TcpOnion3 address format that the stub knows about
    await testTransportEvents(
      TorTransport.new(addrs, upgrade = Upgrade()),
      @[
        MultiAddress
        .init(
          "/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80"
        )
        .tryGet()
      ],
    )
