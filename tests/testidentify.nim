import unittest
import chronos, strutils, sequtils
import ../libp2p/identify, ../libp2p/multiaddress, 
       ../libp2p/peerinfo, ../libp2p/peer, 
       ../libp2p/connection, ../libp2p/identify, 
       ../libp2p/multistream, ../libp2p/transport,
       ../libp2p/tcptransport, ../libp2p/protocol, 
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

        let identifyProto = newProtocol(Identify, peerInfo)
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

        let identifyProto = newProtocol(Identify, peerInfo)
        let res = await msDial.select(conn, IdentifyCodec)

        let id = await identifyProto.identify(conn)
        await conn.close()

        check id.pubKey == remoteSeckey.getKey()
        check id.addrs[0] == ma
        check id.protoVersion == ProtoVersion
        check id.agentVersion == AgentVersion

      await allFutures(receiver(), sender())
      result = true

    check:
      waitFor(testHandle()) == true
  