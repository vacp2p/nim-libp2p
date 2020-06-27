import unittest, options
import chronos, strutils
import ../libp2p/[protocols/identify,
                  multiaddress,
                  peerinfo,
                  peer,
                  stream/connection,
                  multistream,
                  transports/transport,
                  transports/tcptransport,
                  crypto/crypto]
import ./helpers

when defined(nimHasUsed): {.used.}

suite "Identify":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "handle identify message":
    proc testHandle(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let remoteSecKey = PrivateKey.random(ECDSA).get()
      let remotePeerInfo = PeerInfo.init(remoteSecKey,
                                        [ma],
                                        ["/test/proto1/1.0.0",
                                         "/test/proto2/1.0.0"])
      var serverFut: Future[void]
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      var transport1 = TcpTransport.init()
      serverFut = await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      var peerInfo = PeerInfo.init(PrivateKey.random(ECDSA).get(), [ma])
      let identifyProto2 = newIdentify(peerInfo)
      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo)

      check id.pubKey.get() == remoteSecKey.getKey().get()
      check id.addrs[0] == ma
      check id.protoVersion.get() == ProtoVersion
      # check id.agentVersion.get() == AgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      await conn.close()
      await transport1.close()
      await serverFut

      result = true

      await transport2.close()

    check:
      waitFor(testHandle()) == true

  test "handle failed identify":
    proc testHandleError() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      var remotePeerInfo = PeerInfo.init(PrivateKey.random(ECDSA).get(), [ma])
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      let done = newFuture[void]()

      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)
        await conn.close()
        done.complete()

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      var localPeerInfo = PeerInfo.init(PrivateKey.random(ECDSA).get(), [ma])
      let identifyProto2 = newIdentify(localPeerInfo)

      try:
        discard await msDial.select(conn, IdentifyCodec)
        discard await identifyProto2.identify(conn, PeerInfo.init(PrivateKey.random(ECDSA).get()))
      finally:
        await done.wait(5000.millis) # when no issues will not wait that long!
        await conn.close()
        await transport2.close()
        await transport1.close()

    expect IdentityNoMatchError:
      waitFor(testHandleError())
