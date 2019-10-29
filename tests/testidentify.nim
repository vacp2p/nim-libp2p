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

      let remoteSeckey = PrivateKey.random(RSA)
      var remotePeerInfo: PeerInfo
      var serverFut: Future[void]
      remotePeerInfo.peerId = some(PeerID.init(remoteSeckey))
      remotePeerInfo.addrs.add(ma)
      remotePeerInfo.protocols.add("/test/proto1/1.0.0")
      remotePeerInfo.protocols.add("/test/proto2/1.0.0")

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

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = some(PeerID.init(seckey))
      peerInfo.addrs.add(ma)

      let identifyProto2 = newIdentify(peerInfo)
      let res = await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo)

      check id.pubKey.get() == remoteSeckey.getKey()
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

      let remoteSeckey = PrivateKey.random(RSA)
      var remotePeerInfo: PeerInfo
      remotePeerInfo.peerId = some(PeerID.init(remoteSeckey))
      remotePeerInfo.addrs.add(ma)

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

      let seckey = PrivateKey.random(RSA)
      var localPeerInfo: PeerInfo
      localPeerInfo.peerId = some(PeerID.init(seckey))
      localPeerInfo.addrs.add(ma)

      let identifyProto2 = newIdentify(localPeerInfo)
      let res = await msDial.select(conn, IdentifyCodec)

      let wrongSec = PrivateKey.random(RSA)
      var wrongRemotePeer: PeerInfo
      wrongRemotePeer.peerId = some(PeerID.init(wrongSec))

      let id = await identifyProto2.identify(conn, wrongRemotePeer)
      await conn.close()

    expect IdentityNoMatchError:
      waitFor(testHandleError())
