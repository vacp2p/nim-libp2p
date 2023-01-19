import sequtils
import stew/results
import chronos
import ../libp2p/[connmanager,
                  stream/connection,
                  crypto/crypto,
                  muxers/muxer,
                  peerinfo,
                  errors]

import helpers

proc getConnection(peerId: PeerId, dir: Direction = Direction.In): Connection = 
  return Connection.new(peerId, dir, Opt.none(MultiAddress))

type
  TestMuxer = ref object of Muxer
    peerId: PeerId

method newStream*(
  m: TestMuxer,
  name: string = "",
  lazy: bool = false):
  Future[Connection] {.async, gcsafe.} =
  result = getConnection(m.peerId, Direction.Out)

suite "Connection Manager":
  teardown:
    checkTrackers()

  asyncTest "add and retrieve a connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)

    connMngr.storeConn(conn)
    check conn in connMngr

    let peerConn = connMngr.selectConn(peerId)
    check peerConn == conn
    check peerConn.dir == Direction.In

    await connMngr.close()

  asyncTest "shouldn't allow a closed connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)
    await conn.close()

    expect CatchableError:
      connMngr.storeConn(conn)

    await connMngr.close()

  asyncTest "shouldn't allow an EOFed connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)
    conn.isEof = true

    expect CatchableError:
      connMngr.storeConn(conn)

    await conn.close()
    await connMngr.close()

  asyncTest "add and retrieve a muxer":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)
    let muxer = new Muxer
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let peerMuxer = connMngr.selectMuxer(conn)
    check peerMuxer == muxer

    await connMngr.close()

  asyncTest "shouldn't allow a muxer for an untracked connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)
    let muxer = new Muxer
    muxer.connection = conn

    expect CatchableError:
      connMngr.storeMuxer(muxer)

    await conn.close()
    await muxer.close()
    await connMngr.close()

  asyncTest "get conn with direction":
    let connMngr = ConnManager.new(maxConnsPerPeer = 2)
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn1 = getConnection(peerId, Direction.Out)
    let conn2 = getConnection(peerId)

    connMngr.storeConn(conn1)
    connMngr.storeConn(conn2)
    check conn1 in connMngr
    check conn2 in connMngr

    let outConn = connMngr.selectConn(peerId, Direction.Out)
    let inConn = connMngr.selectConn(peerId, Direction.In)

    check outConn != inConn
    check outConn.dir == Direction.Out
    check inConn.dir == Direction.In

    await connMngr.close()

  asyncTest "get muxed stream for peer":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)

    let muxer = new TestMuxer
    muxer.peerId = peerId
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream = await connMngr.getStream(peerId)
    check not(isNil(stream))
    check stream.peerId == peerId

    await connMngr.close()
    await stream.close()

  asyncTest "get stream from directed connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)

    let muxer = new TestMuxer
    muxer.peerId = peerId
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream1 = await connMngr.getStream(peerId, Direction.In)
    check not(isNil(stream1))
    let stream2 = await connMngr.getStream(peerId, Direction.Out)
    check isNil(stream2)

    await connMngr.close()
    await stream1.close()

  asyncTest "get stream from any connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)

    let muxer = new TestMuxer
    muxer.peerId = peerId
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream = await connMngr.getStream(conn)
    check not(isNil(stream))

    await connMngr.close()
    await stream.close()

  asyncTest "should raise on too many connections":
    let connMngr = ConnManager.new(maxConnsPerPeer = 1)
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()

    connMngr.storeConn(getConnection(peerId))

    let conns = @[
        getConnection(peerId),
        getConnection(peerId)]

    expect TooManyConnectionsError:
      connMngr.storeConn(conns[0])
      connMngr.storeConn(conns[1])

    await connMngr.close()

    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "expect connection from peer":
    let connMngr = ConnManager.new(maxConnsPerPeer = 1)
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()

    connMngr.storeConn(getConnection(peerId))

    let conns = @[
        getConnection(peerId),
        getConnection(peerId)]

    expect TooManyConnectionsError:
      connMngr.storeConn(conns[0])

    let
      waitedConn1 = connMngr.expectConnection(peerId)
      waitedConn2 = connMngr.expectConnection(peerId)
      waitedConn3 = connMngr.expectConnection(PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet())
      conn = getConnection(peerId)
    await waitedConn1.cancelAndWait()
    connMngr.storeConn(conn)
    check (await waitedConn2) == conn

    expect TooManyConnectionsError:
      connMngr.storeConn(conns[1])

    await connMngr.close()

    checkExpiring: waitedConn3.cancelled()

    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "cleanup on connection close":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = getConnection(peerId)
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

    await connMngr.close()

  asyncTest "drop connections for peer":
    let connMngr = ConnManager.new(maxConnsPerPeer = 5)
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()

    for i in 0..<2:
      let dir = if i mod 2 == 0:
        Direction.In else:
        Direction.Out

      let conn = getConnection(peerId, dir)
      let muxer = new Muxer
      muxer.connection = conn

      connMngr.storeConn(conn)
      connMngr.storeMuxer(muxer)

      check conn in connMngr
      check muxer in connMngr
      check not(isNil(connMngr.selectConn(peerId, dir)))

    check peerId in connMngr
    await connMngr.dropPeer(peerId)

    check peerId notin connMngr
    check isNil(connMngr.selectConn(peerId, Direction.In))
    check isNil(connMngr.selectConn(peerId, Direction.Out))

    await connMngr.close()

  asyncTest "track total incoming connection limits":
    let connMngr = ConnManager.new(maxConnections = 3)

    for i in 0..<3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should timeout adding a connection over the limit
    check not(await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track total outgoing connection limits":
    let connMngr = ConnManager.new(maxConnections = 3)

    for i in 0..<3:
      discard connMngr.getOutgoingSlot()

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track both incoming and outgoing total connections limits - fail on incoming":
    let connMngr = ConnManager.new(maxConnections = 3)

    for i in 0..<3:
      discard connMngr.getOutgoingSlot()

    # should timeout adding a connection over the limit
    check not(await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track both incoming and outgoing total connections limits - fail on outgoing":
    let connMngr = ConnManager.new(maxConnections = 3)

    for i in 0..<3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track max incoming connection limits":
    let connMngr = ConnManager.new(maxIn = 3)

    for i in 0..<3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    check not(await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track max outgoing connection limits":
    let connMngr = ConnManager.new(maxOut = 3)

    for i in 0..<3:
      discard connMngr.getOutgoingSlot()

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track incoming max connections limits - fail on incoming":
    let connMngr = ConnManager.new(maxOut = 3)

    for i in 0..<3:
      discard connMngr.getOutgoingSlot()

    # should timeout adding a connection over the limit
    check not(await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track incoming max connections limits - fail on outgoing":
    let connMngr = ConnManager.new(maxIn = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "allow force dial":
    let connMngr = ConnManager.new(maxConnections = 2)

    var conns: seq[Connection]
    for i in 0..<3:
      discard connMngr.getOutgoingSlot(true)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot(false)

    await connMngr.close()

  asyncTest "release slot on connection end":
    let connMngr = ConnManager.new(maxConnections = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let slot = connMngr.getOutgoingSlot()

      let conn =
        getConnection(
          PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
          Direction.In)

      slot.trackConnection(conn)
      conns.add(conn)

    # should be full now
    let incomingSlot = connMngr.getIncomingSlot()

    check (await incomingSlot.withTimeout(10.millis)) == false

    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

    check await incomingSlot.withTimeout(10.millis)

    await connMngr.close()
