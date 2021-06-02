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
      remoteSecKey {.threadvar.}: PrivateKey
      remotePeerInfo {.threadvar.}: PeerInfo
      serverFut {.threadvar.}: Future[void]
      acceptFut {.threadvar.}: Future[void]
      pingProto1 {.threadvar.}: Ping
      pingProto2 {.threadvar.}: Ping
      transport1 {.threadvar.}: Transport
      transport2 {.threadvar.}: Transport
      msListen {.threadvar.}: MultistreamSelect
      msDial {.threadvar.}: MultistreamSelect
      conn {.threadvar.}: Connection

    asyncSetup:
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
      remotePeerInfo = PeerInfo.init(
        remoteSecKey, [ma], ["/test/proto1/1.0.0", "/test/proto2/1.0.0"])

      transport1 = TcpTransport.init(upgrade = Upgrade())
      transport2 = TcpTransport.init(upgrade = Upgrade())

      pingProto1 = newPing()
      pingProto2 = newPing()

      msListen = newMultistream()
      msDial = newMultistream()

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
