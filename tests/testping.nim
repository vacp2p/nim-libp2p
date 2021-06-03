import options, bearssl
import chronos, strutils
import ../libp2p/[protocols/identify,
                  protocols/ping,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
                  transports/transport,
                  transports/tcptransport,
                  crypto/crypto,
                  upgrademngrs/upgrade]
import ./helpers

when defined(nimHasUsed): {.used.}

suite "Ping":
  teardown:
    checkTrackers()

  suite "handle ping message":
    var
      ma {.threadvar.}: MultiAddress
      serverFut {.threadvar.}: Future[void]
      acceptFut {.threadvar.}: Future[void]
      pingProto1 {.threadvar.}: Ping
      pingProto2 {.threadvar.}: Ping
      transport1 {.threadvar.}: Transport
      transport2 {.threadvar.}: Transport
      msListen {.threadvar.}: MultistreamSelect
      msDial {.threadvar.}: MultistreamSelect
      conn {.threadvar.}: Connection
      pingReceivedCount {.threadvar.}: int

    asyncSetup:
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      transport1 = TcpTransport.init(upgrade = Upgrade())
      transport2 = TcpTransport.init(upgrade = Upgrade())

      proc handlePing(peer: PeerInfo) {.async, gcsafe, closure.} =
        inc pingReceivedCount
      pingProto1 = newPing()
      pingProto2 = newPing(handlePing)

      msListen = newMultistream()
      msDial = newMultistream()

      pingReceivedCount = 0

    asyncTeardown:
      await conn.close()
      await acceptFut
      await transport1.stop()
      await serverFut
      await transport2.stop()

    asyncTest "simple ping":
      msListen.addHandler(PingCodec, pingProto1)
      serverFut = transport1.start(ma)
      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let c = await transport1.accept()
        await msListen.handle(c)

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.ma)

      discard await msDial.select(conn, PingCodec)
      let time = await pingProto2.ping(conn)

      check not time.isZero()

    asyncTest "ping callback":
      msDial.addHandler(PingCodec, pingProto2)
      serverFut = transport1.start(ma)
      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let c = await transport1.accept()
        discard await msListen.select(c, PingCodec)
        discard await pingProto1.ping(c)

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.ma)

      await msDial.handle(conn)
      check pingReceivedCount == 1
