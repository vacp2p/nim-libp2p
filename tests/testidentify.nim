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
      proc receiver() {.async.} =
        var peerInfo: PeerInfo
        peerInfo.peerId = PeerID.init(remoteSeckey)
        peerInfo.addrs.add(ma)
        peerInfo.protocols.add("/test/proto1/1.0.0")
        peerInfo.protocols.add("/test/proto2/1.0.0")

        let identifyProto = newIdentify(peerInfo)
        let msListen = newMultistream()

        msListen.addHandler(IdentifyCodec, identifyProto)
        proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
          await msListen.handle(conn)

        let transport: TcpTransport = newTransport(TcpTransport)
        await transport.listen(ma, connHandler)

      proc sender() {.async.} =
        let msDial = newMultistream()
        let transport: TcpTransport = newTransport(TcpTransport)
        let conn = await transport.dial(ma)

        let seckey = PrivateKey.random(RSA)
        var peerInfo: PeerInfo
        peerInfo.peerId = PeerID.init(seckey)
        peerInfo.addrs.add(ma)

        let identifyProto = newIdentify(peerInfo)
        let res = await msDial.select(conn, IdentifyCodec)

        let id = await identifyProto.identify(conn)
        await conn.close()

        check id.pubKey == remoteSeckey.getKey()
        check id.addrs[0] == ma
        check id.protoVersion == ProtoVersion
        check id.agentVersion == AgentVersion
        check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      await allFutures(receiver(), sender())
      result = true

    check:
      waitFor(testHandle()) == true
  
  test "handle failed identify":
    proc testHandleError() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53361")

      let remoteSeckey = PrivateKey.random(RSA)
      var remotePeerInfo: PeerInfo
      remotePeerInfo.peerId = PeerID.init(remoteSeckey)
      remotePeerInfo.addrs.add(ma)

      let identifyProto1 = newIdentify(remotePeerInfo)
      let msListen = newMultistream()

      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let seckey = PrivateKey.random(RSA)
      var localPeerInfo: PeerInfo
      localPeerInfo.peerId = PeerID.init(seckey)
      localPeerInfo.addrs.add(ma)

      let identifyProto2 = newIdentify(localPeerInfo)
      let res = await msDial.select(conn, IdentifyCodec)

      let wrongSec = PrivateKey.random(RSA)
      var wrongRemotePeer: PeerInfo
      wrongRemotePeer.peerId = PeerID.init(wrongSec)

      let id = await identifyProto2.identify(conn, some(wrongRemotePeer))
      await conn.close()

    expect IdentityNoMatchError:
      waitFor(testHandleError())
  