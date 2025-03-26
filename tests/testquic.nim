{.used.}

import chronos, stew/byteutils
import
  ../libp2p/[
    stream/connection,
    transports/transport,
    transports/quictransport,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
    wire,
  ]

import ./helpers, ./commontransport

suite "Quic transport":
  asyncTest "can handle local address":
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
    let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    let transport1 = QuicTransport.new(Upgrade(), privateKey)
    await transport1.start(ma)
    check transport1.handles(transport1.addrs[0])
    await transport1.stop()
  #
  asyncTest "transport e2e":
    let serverMA = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
    let clientMA = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
    let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    let server: QuicTransport = QuicTransport.new(Upgrade(), privateKey)
    await server.start(serverMA)

    proc runClient() {.async.} =
      let rng = newRng()
      let privateKey = PrivateKey.random(ECDSA, (rng)[]).tryGet()
      let client: QuicTransport = QuicTransport.new(Upgrade(), privateKey)
      await client.start(clientMA)
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)
      await stream.write("client")
      var resp: array[6, byte]
      await stream.readExactly(addr resp, 6)
      await stream.close()
      check string.fromBytes(resp) == "server"
      await client.stop()

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)
      var resp: array[6, byte]
      await stream.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "client"

      await stream.write("server")
      await stream.close()
      await server.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()
