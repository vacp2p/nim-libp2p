{.used.}

# Nim-Libp2p
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils,tables]
import stew/results
import chronos
import ../libp2p/[connmanager,
                  stream/connection,
                  crypto/crypto,
                  muxers/muxer,
                  peerinfo,
                  errors]

import helpers

proc getMuxer(peerId: PeerId, dir: Direction = Direction.In): Muxer =
  return Muxer(connection: Connection.new(peerId, dir, Opt.none(MultiAddress)))

type
  TestMuxer = ref object of Muxer
    peerId: PeerId

method newStream*(
    m: TestMuxer,
    name: string = "",
    lazy: bool = false
): Future[Connection] {.async: (raises: [
    CancelledError, LPStreamError, MuxerError]).} =
  Connection.new(m.peerId, Direction.Out, Opt.none(MultiAddress))

suite "Connection Manager":
  teardown:
    checkTrackers()

  asyncTest "add and retrieve a muxer":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()
    let mux = getMuxer(peerId)

    connMngr.storeMuxer(mux)
    check mux in connMngr

    let peerMux = connMngr.selectMuxer(peerId)
    check peerMux == mux
    check peerMux.connection.dir == Direction.In

    await connMngr.close()

  asyncTest "get all connections":
    let connMngr = ConnManager.new()

    let peers = toSeq(0..<2).mapIt(PeerId.random.tryGet())
    let muxs = toSeq(0..<2).mapIt(getMuxer(peers[it]))
    for mux in muxs: connMngr.storeMuxer(mux)

    let conns = connMngr.getConnections()
    let connsMux = toSeq(conns.values).mapIt(it[0])
    check unorderedCompare(connsMux, muxs)

    await connMngr.close()

  asyncTest "shouldn't allow a closed connection":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()
    let mux = getMuxer(peerId)
    await mux.connection.close()

    expect CatchableError:
      connMngr.storeMuxer(mux)

    await connMngr.close()

  asyncTest "shouldn't allow an EOFed connection":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()
    let mux = getMuxer(peerId)
    mux.connection.isEof = true

    expect CatchableError:
      connMngr.storeMuxer(mux)

    await mux.close()
    await connMngr.close()

  asyncTest "shouldn't allow a muxer with no connection":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()
    let muxer = getMuxer(peerId)
    let conn = muxer.connection
    muxer.connection = nil

    expect CatchableError:
      connMngr.storeMuxer(muxer)

    await conn.close()
    await muxer.close()
    await connMngr.close()

  asyncTest "get conn with direction":
    # This would work with 1 as well cause of a bug in connmanager that will get fixed soon
    let connMngr = ConnManager.new(maxConnsPerPeer = 2)
    let peerId = randomPeerId()
    let mux1 = getMuxer(peerId, Direction.Out)
    let mux2 = getMuxer(peerId)

    connMngr.storeMuxer(mux1)
    connMngr.storeMuxer(mux2)
    check mux1 in connMngr
    check mux2 in connMngr

    let outMux = connMngr.selectMuxer(peerId, Direction.Out)
    let inMux = connMngr.selectMuxer(peerId, Direction.In)

    check outMux != inMux
    check outMux == mux1
    check inMux == mux2
    check outMux.connection.dir == Direction.Out
    check inMux.connection.dir == Direction.In

    await connMngr.close()

  asyncTest "get muxed stream for peer":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()

    let muxer = new TestMuxer
    let connection = Connection.new(peerId, Direction.In, Opt.none(MultiAddress))
    muxer.peerId = peerId
    muxer.connection = connection

    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream = await connMngr.getStream(peerId)
    check not(isNil(stream))
    check stream.peerId == peerId

    await connMngr.close()
    await connection.close()
    await stream.close()

  asyncTest "get stream from directed connection":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()

    let muxer = new TestMuxer
    let connection = Connection.new(peerId, Direction.In, Opt.none(MultiAddress))
    muxer.peerId = peerId
    muxer.connection = connection

    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream1 = await connMngr.getStream(peerId, Direction.In)
    check not(isNil(stream1))
    let stream2 = await connMngr.getStream(peerId, Direction.Out)
    check isNil(stream2)

    await connMngr.close()
    await stream1.close()
    await connection.close()

  asyncTest "should raise on too many connections":
    let connMngr = ConnManager.new(maxConnsPerPeer = 0)
    let peerId = randomPeerId()

    connMngr.storeMuxer(getMuxer(peerId))

    let muxs = @[getMuxer(peerId)]

    expect TooManyConnectionsError:
      connMngr.storeMuxer(muxs[0])

    await connMngr.close()

    await allFuturesThrowing(
      allFutures(muxs.mapIt( it.close() )))

  asyncTest "expect connection from peer":
    # FIXME This should be 1 instead of 0, it will get fixed soon
    let connMngr = ConnManager.new(maxConnsPerPeer = 0)
    let peerId = randomPeerId()

    connMngr.storeMuxer(getMuxer(peerId))

    let muxs = @[
        getMuxer(peerId),
        getMuxer(peerId)]

    expect TooManyConnectionsError:
      connMngr.storeMuxer(muxs[0])

    let waitedConn1 = connMngr.expectConnection(peerId, In)

    expect AlreadyExpectingConnectionError:
      discard await connMngr.expectConnection(peerId, In)

    await waitedConn1.cancelAndWait()
    let
      waitedConn2 = connMngr.expectConnection(peerId, In)
      waitedConn3 = connMngr.expectConnection(randomPeerId(), In)
      conn = getMuxer(peerId)
    connMngr.storeMuxer(conn)
    check (await waitedConn2) == conn

    expect TooManyConnectionsError:
      connMngr.storeMuxer(muxs[1])

    await connMngr.close()

    checkUntilTimeout: waitedConn3.cancelled()

    await allFuturesThrowing(
      allFutures(muxs.mapIt( it.close() )))

  asyncTest "cleanup on connection close":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()
    let muxer = getMuxer(peerId)

    connMngr.storeMuxer(muxer)

    check muxer in connMngr

    await muxer.close()

    checkUntilTimeout: muxer notin connMngr

    await connMngr.close()

  asyncTest "drop connections for peer":
    let connMngr = ConnManager.new()
    let peerId = randomPeerId()

    for i in 0..<2:
      let dir = if i mod 2 == 0:
        Direction.In else:
        Direction.Out

      let muxer = getMuxer(peerId, dir)

      connMngr.storeMuxer(muxer)

      check muxer in connMngr
      check not(isNil(connMngr.selectMuxer(peerId, dir)))

    check peerId in connMngr
    await connMngr.dropPeer(peerId)

    checkUntilTimeout: peerId notin connMngr
    check isNil(connMngr.selectMuxer(peerId, Direction.In))
    check isNil(connMngr.selectMuxer(peerId, Direction.Out))

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

    for i in 0..<3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "allow force dial":
    let connMngr = ConnManager.new(maxConnections = 2)

    for i in 0..<3:
      discard connMngr.getOutgoingSlot(true)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot(false)

    await connMngr.close()

  asyncTest "release slot on connection end":
    let connMngr = ConnManager.new(maxConnections = 3)

    var muxs: seq[Muxer]
    for i in 0..<3:
      let slot = connMngr.getOutgoingSlot()

      let muxer =
        getMuxer(
          randomPeerId(),
          Direction.In)

      slot.trackMuxer(muxer)
      muxs.add(muxer)

    # should be full now
    let incomingSlot = connMngr.getIncomingSlot()

    check (await incomingSlot.withTimeout(10.millis)) == false

    await allFuturesThrowing(
      allFutures(muxs.mapIt( it.close() )))

    check await incomingSlot.withTimeout(10.millis)

    await connMngr.close()
