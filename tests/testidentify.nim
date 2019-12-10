import unittest, options
import chronos, strutils, sequtils
import ../libp2p/[protocols/identify,
                  multiaddress,
                  peerinfo,
                  peer,
                  connection,
                  multistream,
                  transports/transport,
                  transports/tcptransport,
                  protocols/protocol,
                  crypto/crypto]

when defined(nimHasUsed): {.used.}

suite "Identify":
  test "handle identify message":
    proc testHandle(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      let remoteSecKey = PrivateKey.random(RSA)
      let remotePeerInfo = PeerInfo.init(remoteSecKey,
                                        @[ma],
                                        @["/test/proto1/1.0.0",
                                        "/test/proto2/1.0.0"])
      var serverFut: Future[void]
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      var transport1 = newTransport(TcpTransport)
      serverFut = await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      var peerInfo = PeerInfo.init(PrivateKey.random(RSA), @[ma])
      let identifyProto2 = newIdentify(peerInfo)
      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo)

      check id.pubKey.get() == remoteSecKey.getKey()
      check id.addrs[0] == ma
      check id.protoVersion.get() == ProtoVersion
      # check id.agentVersion.get() == AgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      await conn.close()
      await transport1.close()
      await serverFut
      result = true

    check:
      waitFor(testHandle()) == true

  test "handle failed identify":
    proc testHandleError() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      var remotePeerInfo = PeerInfo.init(PrivateKey.random(RSA), @[ma])
      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      var localPeerInfo = PeerInfo.init(PrivateKey.random(RSA), @[ma])
      let identifyProto2 = newIdentify(localPeerInfo)
      discard await msDial.select(conn, IdentifyCodec)
      discard await identifyProto2.identify(conn, PeerInfo.init(PrivateKey.random(RSA)))
      await conn.close()

    expect IdentityNoMatchError:
      waitFor(testHandleError())
