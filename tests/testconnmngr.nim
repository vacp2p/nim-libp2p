import unittest
import chronos
import ../libp2p/[connmanager,
                  stream/connection,
                  crypto/crypto,
                  muxers/muxer,
                  peerinfo]

import helpers

type
  TestMuxer = ref object of Muxer
    peerInfo: PeerInfo

method newStream*(
  m: TestMuxer,
  name: string = "",
  lazy: bool = false):
  Future[Connection] {.async, gcsafe.} =
  result = Connection.init(m.peerInfo, Direction.Out)

suite "Connection Manager":
  teardown:
    checkTrackers()

  test "add and retrive a connection":
    let connMngr = ConnManager.init()
    let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
    let conn = Connection.init(peer, Direction.In)

    connMngr.storeConn(conn)
    check conn in connMngr

    let peerConn = connMngr.selectConn(peer)
    check peerConn == conn
    check peerConn.dir == Direction.In

  test "add and retrieve a muxer":
    let connMngr = ConnManager.init()
    let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
    let conn = Connection.init(peer, Direction.In)
    let muxer = new Muxer
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let peerMuxer = connMngr.selectMuxer(conn)
    check peerMuxer == muxer

  test "get conn with direction":
    let connMngr = ConnManager.init()
    let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
    let conn1 = Connection.init(peer, Direction.Out)
    let conn2 = Connection.init(peer, Direction.In)

    connMngr.storeConn(conn1)
    connMngr.storeConn(conn2)
    check conn1 in connMngr
    check conn2 in connMngr

    let outConn = connMngr.selectConn(peer, Direction.Out)
    let inConn = connMngr.selectConn(peer, Direction.In)

    check outConn != inConn
    check outConn.dir == Direction.Out
    check inConn.dir == Direction.In

  test "get muxed stream for peer":
    proc test() {.async.} =
      let connMngr = ConnManager.init()
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
      let conn = Connection.init(peer, Direction.In)

      let muxer = new TestMuxer
      muxer.peerInfo = peer
      muxer.connection = conn

      connMngr.storeConn(conn)
      connMngr.storeMuxer(muxer)
      check muxer in connMngr

      let stream = await connMngr.getMuxedStream(peer)
      check not(isNil(stream))
      check stream.peerInfo == peer

    waitFor(test())

  test "get stream from directed connection":
    proc test() {.async.} =
      let connMngr = ConnManager.init()
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
      let conn = Connection.init(peer, Direction.In)

      let muxer = new TestMuxer
      muxer.peerInfo = peer
      muxer.connection = conn

      connMngr.storeConn(conn)
      connMngr.storeMuxer(muxer)
      check muxer in connMngr

      check not(isNil((await connMngr.getMuxedStream(peer, Direction.In))))
      check isNil((await connMngr.getMuxedStream(peer, Direction.Out)))

    waitFor(test())

  test "get stream from any connection":
    proc test() {.async.} =
      let connMngr = ConnManager.init()
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
      let conn = Connection.init(peer, Direction.In)

      let muxer = new TestMuxer
      muxer.peerInfo = peer
      muxer.connection = conn

      connMngr.storeConn(conn)
      connMngr.storeMuxer(muxer)
      check muxer in connMngr

      check not(isNil((await connMngr.getMuxedStream(conn))))

    waitFor(test())

  test "should raise on too many connections":
    proc test() =
      let connMngr = ConnManager.init(1)
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())

      connMngr.storeConn(Connection.init(peer, Direction.In))
      connMngr.storeConn(Connection.init(peer, Direction.In))
      connMngr.storeConn(Connection.init(peer, Direction.In))

    expect TooManyConnections:
      test()

  test "cleanup on connection close":
    proc test() {.async.} =
      let connMngr = ConnManager.init()
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())
      let conn = Connection.init(peer, Direction.In)
      let muxer = new Muxer
      muxer.connection = conn

      connMngr.storeConn(conn)
      connMngr.storeMuxer(muxer)

      check conn in connMngr
      check muxer in connMngr

      await conn.close()
      await sleepAsync(10.millis)

      check conn notin connMngr
      check muxer notin connMngr

    waitFor(test())

  test "drop connections for peer":
    proc test() {.async.} =
      let connMngr = ConnManager.init()
      let peer = PeerInfo.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet())

      for i in 0..<2:
        let dir = if i mod 2 == 0:
          Direction.In else:
          Direction.Out

        let conn = Connection.init(peer, dir)
        let muxer = new Muxer
        muxer.connection = conn

        connMngr.storeConn(conn)
        connMngr.storeMuxer(muxer)

        check conn in connMngr
        check muxer in connMngr
        check not(isNil(connMngr.selectConn(peer, dir)))

      check peer in connMngr.peers
      await connMngr.dropPeer(peer)

      check peer notin connMngr.peers
      check isNil(connMngr.selectConn(peer, Direction.In))
      check isNil(connMngr.selectConn(peer, Direction.Out))
      check connMngr.peers.len == 0

    waitFor(test())
