import unittest, options
import chronos, strutils, sequtils
import ../libp2p/protocols/identify, 
       ../libp2p/multiaddress, 
       ../libp2p/peerinfo, 
       ../libp2p/peer, 
       ../libp2p/connection, 
       ../libp2p/multistream, 
       ../libp2p/transports/transport,
       ../libp2p/transports/tcptransport, 
       ../libp2p/protocols/protocol, 
       ../libp2p/crypto/crypto

suite "Identify":
  test "handle identify message":
    proc testHandle(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53360")

      let remoteSeckey = PrivateKey.random(RSA)
      var remotePeerInfo: PeerInfo
      var serverFut: Future[void]
      var transport: TcpTransport
      proc receiver() {.async.} =
        remotePeerInfo.peerId = some(PeerID.init(remoteSeckey))
        remotePeerInfo.addrs.add(ma)
        remotePeerInfo.protocols.add("/test/proto1/1.0.0")
        remotePeerInfo.protocols.add("/test/proto2/1.0.0")

        let identifyProto = newIdentify(remotePeerInfo)
        let msListen = newMultistream()

        msListen.addHandler(IdentifyCodec, identifyProto)
        proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
          await msListen.handle(conn)

        transport = newTransport(TcpTransport)
        serverFut = await transport.listen(ma, connHandler)

      proc sender() {.async.} =
        let msDial = newMultistream()
        let transport: TcpTransport = newTransport(TcpTransport)
        let conn = await transport.dial(ma)

        let seckey = PrivateKey.random(RSA)
        var peerInfo: PeerInfo
        peerInfo.peerId = some(PeerID.init(seckey))
        peerInfo.addrs.add(ma)

        let identifyProto = newIdentify(peerInfo)
        let res = await msDial.select(conn, IdentifyCodec)
        let id = await identifyProto.identify(conn, remotePeerInfo)

        check id.pubKey.get() == remoteSeckey.getKey()
        check id.addrs[0] == ma
        check id.protoVersion.get() == ProtoVersion
        # check id.agentVersion.get() == AgentVersion
        check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

        await conn.close()

      await allFutures(sender(), receiver())
      await transport.close()
      await serverFut
      result = true

    check:
      waitFor(testHandle()) == true
  
  test "handle failed identify":
    proc testHandleError() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53361")

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
      let conn = await transport2.dial(ma)

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
  