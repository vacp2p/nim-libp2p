import unittest, options, bearssl
import chronos, strutils
import ../libp2p/[protocols/identify,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
                  transports/transport,
                  transports/tcptransport,
                  crypto/crypto]
import ./helpers

when defined(nimHasUsed): {.used.}

suite "Identify":
  teardown:
    checkTrackers()

  test "handle identify message":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
      let remotePeerInfo = PeerInfo.init(remoteSecKey,
                                        [ma],
                                        ["/test/proto1/1.0.0",
                                         "/test/proto2/1.0.0"])
      var serverFut: Future[void]
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)

      var transport1 = TcpTransport.init()
      serverFut = transport1.start(ma)

      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let conn = await transport1.accept()
        await msListen.handle(conn)

      let acceptFut = acceptHandler()
      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      var peerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get(), [ma])
      let identifyProto2 = newIdentify(peerInfo)
      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo)

      check id.pubKey.get() == remoteSecKey.getKey().get()
      check id.addrs[0] == ma
      check id.protoVersion.get() == ProtoVersion
      # check id.agentVersion.get() == AgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      await conn.close()
      await acceptFut
      await transport1.stop()
      await serverFut
      await transport2.stop()

    waitFor(test())

  test "handle failed identify":
    proc testHandleError(): Future[bool] {.async.} =
      let ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      var remotePeerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get(), [ma])
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.start(ma)

      proc acceptHandler() {.async.} =
        var conn: Connection
        try:
          conn = await transport1.accept()
          await msListen.handle(conn)
        except CatchableError:
          discard
        finally:
          await conn.close()

      let acceptFut = acceptHandler()
      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)
      var localPeerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get(), [ma])
      let identifyProto2 = newIdentify(localPeerInfo)

    expect IdentityNoMatchError:
      try:
        let pi2 = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
        discard await msDial.select(conn, IdentifyCodec)
        discard await identifyProto2.identify(conn, pi2)
      except IdentityNoMatchError:
        result = true

      await conn.close()
      await acceptFut.wait(5000.millis) # when no issues will not wait that long!
      await transport2.stop()
      await transport1.stop()

    check:
      waitFor(testHandleError()) == true
