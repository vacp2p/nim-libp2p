# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results, chronos, std/[sequtils, tables, strformat]
import
  ../../libp2p/[connmanager, stream/connection, crypto/crypto, muxers/muxer, peerinfo]
import ../tools/[unittest, compare, futures, crypto]

proc makeMuxer(peerId: PeerId, dir: Direction = Direction.In): Muxer =
  return Muxer(connection: Connection.new(peerId, dir))

type TestMuxer = ref object of Muxer
  peerId: PeerId

method newStream*(
    m: TestMuxer, name: string = "", lazy: bool = false
): Future[Connection] {.async: (raises: [CancelledError, LPStreamError, MuxerError]).} =
  Connection.new(m.peerId, Direction.Out)

proc newMaxTotal(maxConnections = 10, maxConnsPerPeer = 1): ConnManager =
  ConnManager.new(
    maxConnsPerPeer = maxConnsPerPeer,
    limits = Opt.some(LimitsConfig.maxTotal(maxConnections)),
  )

proc newMaxInOut(maxIn: int, maxOut: int, maxConnsPerPeer = 1): ConnManager =
  ConnManager.new(
    maxConnsPerPeer = maxConnsPerPeer,
    limits = Opt.some(LimitsConfig.maxInOut(maxIn, maxOut)),
  )

proc newWatermark*(
    lowWater: int,
    highWater: int,
    gracePeriod: Duration = 0.seconds,
    silencePeriod: Duration = 0.seconds,
    outboundBonus: int = 0,
    decayResolution = 1.minutes,
): ConnManager =
  let wtCfg = WatermarkConfig(
    lowWater: lowWater,
    highWater: highWater,
    gracePeriod: gracePeriod,
    silencePeriod: silencePeriod,
  )
  let scCfg =
    ScoringConfig(outboundBonus: outboundBonus, decayResolution: decayResolution)
  ConnManager.new(watermark = Opt.some(wtCfg), scoringConfig = scCfg)

proc storeMuxers(connMngr: ConnManager, count: uint): Future[seq[PeerId]] {.async.} =
  let peers = PeerId.random(count, rng).tryGet()
  await allFuturesRaising(peers.mapIt(connMngr.storeMuxer(makeMuxer(it))))
  return peers

suite "Connection Manager":
  teardown:
    checkTrackers()

  let peerId = PeerId.random(rng).tryGet()

  asyncTest "add and retrieve a muxer":
    let connMngr = newMaxTotal()
    let mux = makeMuxer(peerId)

    await connMngr.storeMuxer(mux)
    check mux in connMngr

    let peerMux = connMngr.selectMuxer(peerId)
    check peerMux == mux
    check peerMux.connection.dir == Direction.In

    await connMngr.close()

  asyncTest "get all connections":
    let connMngr = newMaxTotal()

    let peers = PeerId.random(5, rng).tryGet()
    let muxs = peers.mapIt(makeMuxer(it))
    for mux in muxs:
      await connMngr.storeMuxer(mux)

    let connsMux = connMngr.getConnections().values.toSeq().mapIt(it[0])
    check unorderedCompare(connsMux, muxs)

    await connMngr.close()

  asyncTest "shouldn't allow a closed connection":
    let connMngr = newMaxTotal()

    let mux = makeMuxer(peerId)
    await mux.connection.close()
    expect LPError:
      await connMngr.storeMuxer(mux)

    await connMngr.close()

  asyncTest "shouldn't allow an EOFed connection":
    let connMngr = newMaxTotal()

    let mux = makeMuxer(peerId)
    mux.connection.isEof = true
    expect LPError:
      await connMngr.storeMuxer(mux)

    await mux.close()
    await connMngr.close()

  asyncTest "shouldn't allow a muxer with no connection":
    let connMngr = newMaxTotal()

    let muxer = makeMuxer(peerId)
    let conn = muxer.connection
    muxer.connection = nil
    expect LPError:
      await connMngr.storeMuxer(muxer)

    await conn.close()
    await muxer.close()
    await connMngr.close()

  asyncTest "get conn with direction":
    let connMngr = newMaxTotal(maxConnsPerPeer = 2)

    let mux1 = makeMuxer(peerId, Direction.Out)
    let mux2 = makeMuxer(peerId)

    await connMngr.storeMuxer(mux1)
    await connMngr.storeMuxer(mux2)
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
    let connMngr = newMaxTotal()

    let muxer = new TestMuxer
    let connection = Connection.new(peerId, Direction.In)
    muxer.peerId = peerId
    muxer.connection = connection

    await connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream = await connMngr.getStream(peerId)
    check not stream.isNil
    check stream.peerId == peerId

    await connMngr.close()
    await connection.close()
    await stream.close()

  asyncTest "get stream from directed connection":
    let connMngr = newMaxTotal()

    let muxer = new TestMuxer
    let connection = Connection.new(peerId, Direction.In)
    muxer.peerId = peerId
    muxer.connection = connection

    await connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let stream1 = await connMngr.getStream(peerId, Direction.In)
    check not stream1.isNil
    let stream2 = await connMngr.getStream(peerId, Direction.Out)
    check stream2.isNil

    await connMngr.close()
    await stream1.close()
    await connection.close()

  asyncTest "expect connection from peer":
    let connMngr = newMaxTotal(maxConnsPerPeer = 1)

    let muxs = @[makeMuxer(peerId), makeMuxer(peerId)]

    await connMngr.storeMuxer(muxs[0])
    expect TooManyConnectionsError:
      await connMngr.storeMuxer(muxs[1])

    let waitedConn1 = connMngr.expectConnection(peerId, In)

    expect AlreadyExpectingConnectionError:
      discard await connMngr.expectConnection(peerId, In)

    await waitedConn1.cancelAndWait()
    let
      waitedConn2 = connMngr.expectConnection(peerId, In)
      waitedConn3 = connMngr.expectConnection(PeerId.random(rng).tryGet(), In)
      conn = makeMuxer(peerId)
    await connMngr.storeMuxer(conn)
    check (await waitedConn2) == conn

    expect TooManyConnectionsError:
      await connMngr.storeMuxer(muxs[1])

    await connMngr.close()

    checkUntilTimeout:
      waitedConn3.cancelled()

    await allFuturesRaising(muxs.mapIt(it.close()))

  asyncTest "cleanup on connection close":
    let connMngr = newMaxTotal()
    let muxer = makeMuxer(peerId)

    await connMngr.storeMuxer(muxer)
    check muxer in connMngr

    await muxer.close()
    checkUntilTimeout:
      muxer notin connMngr

    await connMngr.close()

  asyncTest "waitForPeerReady unblocks when muxer is stored":
    let connMngr = newMaxTotal()

    let readyWaiter = connMngr.waitForPeerReady(peerId, 1.seconds)
    await connMngr.storeMuxer(makeMuxer(peerId))

    check await readyWaiter
    await connMngr.close()

  asyncTest "waitForPeerReady timeout does not break concurrent waiters":
    let connMngr = newMaxTotal()

    let shortWaiter = connMngr.waitForPeerReady(peerId, 10.millis)
    let longWaiter = connMngr.waitForPeerReady(peerId, 1.seconds)

    check not (await shortWaiter)
    await connMngr.storeMuxer(makeMuxer(peerId))
    check await longWaiter

    await connMngr.close()

  asyncTest "waitForPeerReady cleanup after disconnect":
    let connMngr = newMaxTotal()
    let muxer = makeMuxer(peerId)

    await connMngr.storeMuxer(muxer)
    await muxer.close()

    checkUntilTimeout:
      peerId notin connMngr

    check (await connMngr.waitForPeerReady(peerId, 10.millis)) == false
    await connMngr.close()

  asyncTest "drop connections for peer":
    let connMngr = newMaxTotal(maxConnsPerPeer = 2)

    for i in 0 ..< 2:
      let dir = if i mod 2 == 0: Direction.In else: Direction.Out

      let muxer = makeMuxer(peerId, dir)
      await connMngr.storeMuxer(muxer)
      check muxer in connMngr
      check not connMngr.selectMuxer(peerId, dir).isNil

    check peerId in connMngr
    await connMngr.dropPeer(peerId)

    checkUntilTimeout:
      peerId notin connMngr
    check connMngr.selectMuxer(peerId, Direction.In).isNil
    check connMngr.selectMuxer(peerId, Direction.Out).isNil

    await connMngr.close()

  asyncTest "track total incoming connection limits":
    let connMngr = newMaxTotal(3)

    for i in 0 ..< 3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should timeout adding a connection over the limit
    check not (await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track total outgoing connection limits":
    let connMngr = newMaxTotal(3)

    for i in 0 ..< 3:
      discard connMngr.getOutgoingSlot()

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track both incoming and outgoing total connections limits - fail on incoming":
    let connMngr = newMaxTotal(3)

    for i in 0 ..< 3:
      discard connMngr.getOutgoingSlot()

    # should timeout adding a connection over the limit
    check not (await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track both incoming and outgoing total connections limits - fail on outgoing":
    let connMngr = newMaxTotal(3)

    for i in 0 ..< 3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track max incoming connection limits":
    let connMngr = newMaxInOut(3, 1)

    for i in 0 ..< 3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    check not (await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track max outgoing connection limits":
    let connMngr = newMaxInOut(1, 3)

    for i in 0 ..< 3:
      discard connMngr.getOutgoingSlot()

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "track incoming max connections limits - fail on incoming":
    let connMngr = newMaxInOut(1, 3)

    for i in 0 ..< 3:
      discard connMngr.getOutgoingSlot()

    check await connMngr.getIncomingSlot().withTimeout(10.millis)

    # should timeout adding a connection over the limit
    check not (await connMngr.getIncomingSlot().withTimeout(10.millis))

    await connMngr.close()

  asyncTest "track incoming max connections limits - fail on outgoing":
    let connMngr = newMaxInOut(3, 1)

    for i in 0 ..< 3:
      check await connMngr.getIncomingSlot().withTimeout(10.millis)

    discard connMngr.getOutgoingSlot()

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

  asyncTest "allow force dial":
    let connMngr = newMaxTotal(2)

    for i in 0 ..< 3:
      discard connMngr.getOutgoingSlot(true)

    # should throw adding a connection over the limit
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot(false)

    await connMngr.close()

  asyncTest "release slot on connection end":
    let connMngr = newMaxTotal(3)

    var muxs: seq[Muxer]
    for i in 0 ..< 3:
      let slot = connMngr.getOutgoingSlot()
      let muxer = makeMuxer(PeerId.random(rng).tryGet(), Direction.In)

      slot.trackMuxer(muxer)
      muxs.add(muxer)

    let incomingSlot = connMngr.getIncomingSlot()

    # should be full now
    check not (await incomingSlot.withTimeout(10.millis))

    # should have slots after closing muxers
    await allFuturesRaising(muxs.mapIt(it.close()))
    check await incomingSlot.withTimeout(10.millis)

    await connMngr.close()

suite "Connection Manager maxConnsPerPeer":
  teardown:
    checkTrackers()

  let peerId = PeerId.random(rng).tryGet()
  const defaultMaxConnsPerPeer = 2

  proc runTest(maxConnsPerPeer: int, numberOfMuxersToConnect: int) {.async.} =
    let connMngr = newMaxTotal(maxConnsPerPeer = maxConnsPerPeer)

    # store up to limit
    for _ in 0 ..< numberOfMuxersToConnect:
      await connMngr.storeMuxer(makeMuxer(peerId))

    check connMngr.connCount(peerId) == numberOfMuxersToConnect

    # add one more to exceed limit
    expect TooManyConnectionsError:
      let extraMuxer = makeMuxer(peerId)
      try:
        await connMngr.storeMuxer(extraMuxer)
      finally:
        await extraMuxer.close()

    check connMngr.connCount(peerId) == numberOfMuxersToConnect

    await connMngr.close()

  asyncTest "maxConnsPerPeer = -1 uses default":
    await runTest(-1, defaultMaxConnsPerPeer)

  asyncTest "maxConnsPerPeer = 0 uses default":
    await runTest(0, defaultMaxConnsPerPeer)

  for i in 1 ..< 10:
    let limit = i
    asyncTest fmt"peer limit is reached with {limit} muxers":
      await runTest(limit, limit)

suite "Connection Manager Watermark":
  teardown:
    checkTrackers()

  let peerId = PeerId.random(rng).tryGet()

  asyncTest "trim fires when peer count exceeds highWater":
    const peersToConnect = 5
    const lowWater = 2
    const highWater = peersToConnect - 1 # connect 1 peer above high water
    let connMngr = newWatermark(lowWater, highWater)

    # connect peers - one over the highWater
    discard await storeMuxers(connMngr, peersToConnect)

    check connMngr.getConnections().len == lowWater

    await connMngr.close()

  asyncTest "grace period protects newly connected peers":
    # long grace period - newly connected peers must not be pruned
    const peersToConnect = 5
    const lowWater = 1
    const highWater = peersToConnect - 3
    let connMngr = newWatermark(lowWater, highWater, gracePeriod = 1.hours)

    discard await storeMuxers(connMngr, peersToConnect)

    # all peers are within grace period - none should be pruned
    check connMngr.getConnections().len == peersToConnect

    await connMngr.close()

  asyncTest "protected peers survive trim":
    const peersToConnect = 3
    const lowWater = 1
    const highWater = peersToConnect
    let connMngr = newWatermark(lowWater, highWater)

    let peers = await storeMuxers(connMngr, peersToConnect)

    # protect the first two peers before the trim-triggering store
    connMngr.protect(peers[0], "important")
    connMngr.protect(peers[1], "important")

    # adding extra peer, triggering trim
    await connMngr.storeMuxer(makeMuxer(peerId))

    # protected peers must still be connected
    check connMngr.contains(peers[0])
    check connMngr.contains(peers[1])

    await connMngr.close()

  asyncTest "unprotect removes tag and allows trimming":
    let connMngr = newWatermark(1, 3)

    await connMngr.storeMuxer(makeMuxer(peerId))

    connMngr.protect(peerId, "tag-a")
    connMngr.protect(peerId, "tag-b")

    check connMngr.isProtected(peerId)
    check connMngr.unprotect(peerId, "tag-a") == true # still protected via tag-b
    check connMngr.unprotect(peerId, "tag-b") == false # no longer protected
    check not connMngr.isProtected(peerId)

    await connMngr.close()

  asyncTest "silence period throttles back-to-back trims":
    const peersToConnect = 3
    const highWater = peersToConnect - 1
    let connMngr = newWatermark(1, highWater, silencePeriod = 1.hours)

    # connect first batch of peers - should cause trim after last peer
    discard await storeMuxers(connMngr, peersToConnect)

    let connectedPeers = connMngr.getConnections().len

    # connect second batch of peers.
    # silence period prevents a second trim,
    # adding more peers should not immediately trigger another trim
    discard await storeMuxers(connMngr, peersToConnect)

    # silence period still active - count should be >= before
    check connMngr.getConnections().len == connectedPeers + peersToConnect

    await connMngr.close()

  asyncTest "getIncomingSlot does not block in watermark mode":
    let connMngr = newWatermark(1, 5)

    # should return immediately without semaphore blocking
    check await connMngr.getIncomingSlot().withTimeout(10.millis)

    await connMngr.close()

  asyncTest "getOutgoingSlot does not raise in watermark mode":
    let connMngr = newWatermark(1, 5)

    for i in 0 ..< 10:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()

suite "Connection Manager Scoring":
  teardown:
    checkTrackers()

  const tag = "λ"
  let peerId = PeerId.random(rng).tryGet()

  asyncTest "peerScore returns 0 for unknown peer":
    let cm = newWatermark(1, 2)
    check cm.peerScore(peerId) == 0
    await cm.close()

  asyncTest "static tag contributes to peer score":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeer(peerId, "🌞", 50)
    check cm.peerScore(peerId) == 50
    cm.tagPeer(peerId, "🕶️", 30)
    check cm.peerScore(peerId) == 80
    await cm.close()

  asyncTest "untagPeer removes score contribution":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeer(peerId, tag, 50)
    cm.untagPeer(peerId, tag)
    check cm.peerScore(peerId) == 0
    await cm.close()

  asyncTest "outbound connection gets outboundBonus":
    const outboundBonus = 2345432
    let cm = newWatermark(1, 2, outboundBonus = outboundBonus)
    await cm.storeMuxer(makeMuxer(peerId, Direction.Out))
    check cm.peerScore(peerId) == outboundBonus
    await cm.close()

  asyncTest "inbound connection gets no outboundBonus":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId, Direction.In))
    check cm.peerScore(peerId) == 0
    await cm.close()

  asyncTest "decaying tag contributes initial value to score":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeerDecaying(peerId, tag, 100, 1.hours, decayLinear(0.5))
    check cm.peerScore(peerId) == 100
    await cm.close()

  asyncTest "decaying tag value decreases over interval":
    let cm = newWatermark(1, 2, decayResolution = 20.millis)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeerDecaying(peerId, tag, 100, 20.millis, decayFixed(30))
    checkUntilTimeout:
      cm.peerScore(peerId) < 100
    await cm.close()

  asyncTest "decaying tag auto-removed when value hits zero":
    let cm = newWatermark(1, 2, decayResolution = 20.millis)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeerDecaying(peerId, tag, 10, 20.millis, decayFixed(15))
    checkUntilTimeout:
      cm.peerScore(peerId) == 0
    await cm.close()

  asyncTest "bumpDecayingTag increases tag value":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeerDecaying(peerId, tag, 50, 1.hours, decayNone())
    cm.bumpDecayingTag(peerId, tag, 25)
    check cm.peerScore(peerId) == 75
    await cm.close()

  asyncTest "removeDecayingTag removes tag immediately":
    let cm = newWatermark(1, 2)
    await cm.storeMuxer(makeMuxer(peerId))
    cm.tagPeerDecaying(peerId, tag, 50, 1.hours, decayNone())
    cm.removeDecayingTag(peerId, tag)
    check cm.peerScore(peerId) == 0
    await cm.close()

  asyncTest "watermark trim prunes lowest-score peer first":
    let cm = newWatermark(1, 2)
    let highScorePeer = PeerId.random(rng).tryGet()
    let lowScorePeer1 = PeerId.random(rng).tryGet()
    await cm.storeMuxer(makeMuxer(highScorePeer))
    cm.tagPeer(highScorePeer, "destacado", 500)
    await cm.storeMuxer(makeMuxer(lowScorePeer1))
    # store a third peer to trigger trim (count=3 > highWater=2)
    await cm.storeMuxer(makeMuxer(PeerId.random(rng).tryGet()))
    check cm.contains(highScorePeer)
    check cm.getConnections().len == 1
    await cm.close()

  asyncTest "outbound peer survives watermark trim over inbound peers":
    let cm = newWatermark(1, 2, outboundBonus = 500)
    let outboundPeer = PeerId.random(rng).tryGet()
    await cm.storeMuxer(makeMuxer(outboundPeer, Direction.Out))
    await cm.storeMuxer(makeMuxer(PeerId.random(rng).tryGet(), Direction.In))
    # add one more over the high water to trigger the trim
    await cm.storeMuxer(makeMuxer(PeerId.random(rng).tryGet(), Direction.In))
    check cm.contains(outboundPeer)
    check cm.getConnections().len == 1
    await cm.close()

suite "Connection Manager: watermark with connection limiting":
  teardown:
    checkTrackers()

  asyncTest "protected peers fill semaphore cap blocking new connections":
    # both connection limiting (maxConnections=3) and watermark trimming (highWater=2)
    # are active simultaneously. protected peers survive every trim cycle, so the
    # semaphore stays exhausted and all further connection attempts are rejected.
    const maxConns = 3
    let connMngr = ConnManager.new(
      limits = Opt.some(LimitsConfig.maxTotal(maxConns)),
      watermark = Opt.some(
        WatermarkConfig(
          lowWater: 1, highWater: 2, gracePeriod: 0.seconds, silencePeriod: 0.seconds
        )
      ),
    )

    # acquire a semaphore slot for each peer, protect it, then register it.
    # protecting before storeMuxer ensures the peer is already shielded when
    # trim fires on the 3rd store (peer count 3 > highWater 2).
    for _ in 0 ..< maxConns:
      let peerId = PeerId.random(rng).tryGet()
      let slot = await connMngr.getIncomingSlot()
      let muxer = makeMuxer(peerId)
      connMngr.protect(peerId, "keep-forever")
      slot.trackMuxer(muxer)
      await connMngr.storeMuxer(muxer)

    # trim fired but found no unprotected candidates, all 3 peers still connected
    check connMngr.getConnections().len == maxConns

    # all connection slots should be used, getting incoming slot must block
    check not (await connMngr.getIncomingSlot().withTimeout(50.millis))

    # getting outgoing slot must raise (all slots are used)
    expect TooManyConnectionsError:
      discard connMngr.getOutgoingSlot()

    await connMngr.close()
