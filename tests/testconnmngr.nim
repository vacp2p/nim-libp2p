import sequtils
import chronos
import ../libp2p/[connmanager,
                  stream/connection,
                  crypto/crypto,
                  muxers/muxer,
                  peerinfo,
                  errors]

import helpers

type
  TestMuxer = ref object of Muxer
    peerId: PeerId

method newStream*(
  m: TestMuxer,
  name: string = "",
  lazy: bool = false):
  Future[Connection] {.async, gcsafe.} =
  result = Connection.new(m.peerId, Direction.Out)

suite "Connection Manager":
  teardown:
    checkTrackers()

  asyncTest "add and retrieve a connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = Connection.new(peerId, Direction.In)

    connMngr.storeConn(conn)
    check conn in connMngr

    let peerConn = connMngr.selectConn(peerId)
    check peerConn == conn
    check peerConn.dir == Direction.In

    await connMngr.close()

  asyncTest "shouldn't allow a closed connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = Connection.new(peerId, Direction.In)
    await conn.close()

    expect CatchableError:
      connMngr.storeConn(conn)

    await connMngr.close()

  asyncTest "shouldn't allow an EOFed connection":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = Connection.new(peerId, Direction.In)
    conn.isEof = true

    expect CatchableError:
      connMngr.storeConn(conn)

    await conn.close()
    await connMngr.close()

  asyncTest "add and retrieve a muxer":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = Connection.new(peerId, Direction.In)
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
    let conn = Connection.new(peerId, Direction.In)
    let muxer = new Muxer
    muxer.connection = conn

    expect CatchableError:
      connMngr.storeMuxer(muxer)

    await conn.close()
    await muxer.close()
    await connMngr.close()

  asyncTest "get conn with direction":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn1 = Connection.new(peerId, Direction.Out)
    let conn2 = Connection.new(peerId, Direction.In)

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
    let conn = Connection.new(peerId, Direction.In)

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
    let conn = Connection.new(peerId, Direction.In)

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
    let conn = Connection.new(peerId, Direction.In)

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

    connMngr.storeConn(Connection.new(peerId, Direction.In))

    let conns = @[
        Connection.new(peerId, Direction.In),
        Connection.new(peerId, Direction.In)]

    expect TooManyConnectionsError:
      connMngr.storeConn(conns[0])
      connMngr.storeConn(conns[1])

    await connMngr.close()

    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "cleanup on connection close":
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    let conn = Connection.new(peerId, Direction.In)
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
    let connMngr = ConnManager.new()
    let peerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()

    for i in 0..<2:
      let dir = if i mod 2 == 0:
        Direction.In else:
        Direction.Out

      let conn = Connection.new(peerId, dir)
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

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      check await conn.withTimeout(10.millis)
      conns.add(await conn)

    # should timeout adding a connection over the limit
    let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

    check not(await conn.withTimeout(10.millis))

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track total outgoing connection limits":
    let connMngr = ConnManager.new(maxConnections = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = await connMngr.trackOutgoingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      conns.add(conn)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard await connMngr.trackOutgoingConn(
          proc(): Future[Connection] {.async.} =
            return Connection.new(
              PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
              Direction.In)
        )

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track both incoming and outgoing total connections limits - fail on incoming":
    let connMngr = ConnManager.new(maxConnections = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = await connMngr.trackOutgoingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      conns.add(conn)

    # should timeout adding a connection over the limit
    let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

    check not(await conn.withTimeout(10.millis))

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track both incoming and outgoing total connections limits - fail on outgoing":
    let connMngr = ConnManager.new(maxConnections = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      check await conn.withTimeout(10.millis)
      conns.add(await conn)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard await connMngr.trackOutgoingConn(
          proc(): Future[Connection] {.async.} =
            return Connection.new(
              PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
              Direction.In)
        )

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track max incoming connection limits":
    let connMngr = ConnManager.new(maxIn = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      check await conn.withTimeout(10.millis)
      conns.add(await conn)

    # should timeout adding a connection over the limit
    let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

    check not(await conn.withTimeout(10.millis))

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track max outgoing connection limits":
    let connMngr = ConnManager.new(maxOut = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = await connMngr.trackOutgoingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      conns.add(conn)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard await connMngr.trackOutgoingConn(
          proc(): Future[Connection] {.async.} =
            return Connection.new(
              PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
              Direction.In)
        )

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track incoming max connections limits - fail on incoming":
    let connMngr = ConnManager.new(maxOut = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = await connMngr.trackOutgoingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      conns.add(conn)

    # should timeout adding a connection over the limit
    let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

    check not(await conn.withTimeout(10.millis))

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "track incoming max connections limits - fail on outgoing":
    let connMngr = ConnManager.new(maxIn = 3)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = connMngr.trackIncomingConn(
        proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
      )

      check await conn.withTimeout(10.millis)
      conns.add(await conn)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard await connMngr.trackOutgoingConn(
          proc(): Future[Connection] {.async.} =
            return Connection.new(
              PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
              Direction.In)
        )

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))

  asyncTest "allow force dial":
    let connMngr = ConnManager.new(maxConnections = 2)

    var conns: seq[Connection]
    for i in 0..<3:
      let conn = connMngr.trackOutgoingConn(
        (proc(): Future[Connection] {.async.} =
          return Connection.new(
            PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
            Direction.In)
        ), true
      )

      check await conn.withTimeout(10.millis)
      conns.add(await conn)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard await connMngr.trackOutgoingConn(
          (proc(): Future[Connection] {.async.} =
            return Connection.new(
              PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet(),
              Direction.In)
          ), false
        )

    await connMngr.close()
    await allFuturesThrowing(
      allFutures(conns.mapIt( it.close() )))
