{.used.}

import sequtils
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
    let serverMA = @[MultiAddress.init("/ip4/127.0.0.1/udp/50001/quic-v1").tryGet()] # todo: HANDLE 0 port
    let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    let server: QuicTransport = QuicTransport.new(Upgrade(), privateKey)
    await server.start(serverMA)

    proc runClient() {.async.} =
      let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
      let client: QuicTransport = QuicTransport.new(Upgrade(), privateKey)
      let conn = await client.dial("", server.addrs[0])
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
