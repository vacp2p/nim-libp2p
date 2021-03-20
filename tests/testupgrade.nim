import unittest, tables
import chronos

import ../libp2p
import ../libp2p/upgrademngrs/muxedupgrade

import ./helpers

proc createMuxedManager(
  seckey = PrivateKey.random(rng[]).tryGet(),
  ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()): Upgrade =

  proc createMplex(conn: Connection): Muxer =
    Mplex.init(conn)

  let
    peerInfo = PeerInfo.init(seckey, [ma])
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)

  return MuxedUpgrade.init(
          newIdentify(peerInfo),
          {MplexCodec: mplexProvider}.toTable,
          [newNoise(rng, seckey).Secure],
          ConnManager.init(),
          newMultistream())

suite "Test Upgrade Managers":

  asyncTest "Test Identify flow":
    let
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      seckey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.init(seckey, [ma])
      upgrade = createMuxedManager()
      transport1 = TcpTransport.init(upgrade = Upgrade())
      transport2 = TcpTransport.init(upgrade = upgrade)
      identifyProto = newIdentify(peerInfo)
      msListen = newMultistream()

    peerInfo.agentVersion = AgentVersion
    peerInfo.protoVersion = ProtoVersion

    msListen.addHandler(IdentifyCodec, identifyProto)
    let serverFut = transport1.start(ma)
    proc acceptHandler(): Future[void] {.async, gcsafe.} =
      let c = await transport1.accept()
      await msListen.handle(c)

    let acceptFut = acceptHandler()
    let conn = await transport2.dial(transport1.ma)

    check isNil(conn.peerInfo)
    await upgrade.identify(conn)

    check:
      not isNil(conn.peerInfo)
      conn.peerInfo.peerId == peerInfo.peerId
      conn.peerInfo.addrs == peerInfo.addrs
      conn.peerInfo.agentVersion == peerInfo.agentVersion
      conn.peerInfo.protoVersion == peerInfo.protoVersion
      conn.peerInfo.protocols == peerInfo.protocols

    await allFuturesThrowing(
      transport1.stop(),
      transport2.stop(),
      acceptFut,
      serverFut
    )

  asyncTest "Test Secure flow":
    let
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      seckey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.init(seckey, [ma])
      upgrade = createMuxedManager()
      transport1 = TcpTransport.init(upgrade = Upgrade())
      transport2 = TcpTransport.init(upgrade = upgrade)
      secure = newNoise(rng, seckey).Secure
      msListen = newMultistream()

    peerInfo.agentVersion = AgentVersion
    peerInfo.protoVersion = ProtoVersion

    msListen.addHandler(NoiseCodec, secure)
    let serverFut = transport1.start(ma)
    proc acceptHandler(): Future[void] {.async, gcsafe.} =
      let c = await transport1.accept()
      await msListen.handle(c)

    let acceptFut = acceptHandler()
    let conn = await transport2.dial(transport1.ma)

    check isNil(conn.peerInfo)
    let sconn = await upgrade.secure(conn)
    check:
      not isNil(sconn)
      sconn.transportDir == Direction.Out

    await allFuturesThrowing(
      transport1.stop(),
      transport2.stop(),
      acceptFut,
      serverFut
    )
