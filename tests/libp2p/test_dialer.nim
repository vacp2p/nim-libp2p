# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, sequtils, results
import ../../libp2p/[builders, switch]
import ../tools/[unittest, futures, switch_builder, crypto, multiaddress]

type StallServer = ref object
  ## A remote that accepts the connection and then never speaks, so the dialer
  ## blocks in the security handshake with nothing to read.
  server: StreamServer
  accepted: seq[StreamTransport]
  address: MultiAddress

proc startStallServer(): StallServer =
  let stall = StallServer()

  proc acceptAndStall(
      server: StreamServer, client: StreamTransport
  ) {.async: (raises: []).} =
    stall.accepted.add(client)

  stall.server =
    createStreamServer(initTAddress("127.0.0.1:0"), acceptAndStall, {ReuseAddr})
  stall.server.start()
  # `local` carries the address the socket really bound, port 0 resolved.
  stall.address = MultiAddress.init(stall.server.local).tryGet()
  stall

proc stop(stall: StallServer) {.async: (raises: []).} =
  # `stop2` over `stop`: the raising variant would break `raises: []` here.
  stall.server.stop2().isOkOr:
    raiseAssert "stall server stop failed"
  await stall.server.closeWait()
  await noCancel allFutures(stall.accepted.mapIt(it.closeWait()))

suite "Dialer":
  teardown:
    checkTrackers()

  asyncTest "Connect forces a new connection":
    let
      src = makeStandardSwitchBuilder().withMaxConnsPerPeer(2).build()
      dst = makeStandardSwitchBuilder().withMaxConnsPerPeer(2).build()

    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    check src.connManager.connCount(dst.peerInfo.peerId) == 1

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    check src.connManager.connCount(dst.peerInfo.peerId) == 1

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)
    check src.connManager.connCount(dst.peerInfo.peerId) == 2

    await allFutures(src.stop(), dst.stop())

  asyncTest "Max connections reached":
    var switches: seq[Switch]

    let dst = makeStandardSwitchBuilder()
      .withConnectionLimits(ConnectionLimits.maxTotal(2))
      .build()
    await dst.start()
    switches.add(dst)

    for i in 1 ..< 3:
      let src = makeStandardSwitch()
      switches.add(src)
      await src.start()
      await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)

    let src = makeStandardSwitch()
    switches.add(src)
    await src.start()
    check not await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs).withTimeout(
      1000.millis
    )

    await allFuturesRaising(switches.mapIt(it.stop()))

  asyncTest "A stalling remote gives up at the dial timeout":
    let
      stall = startStallServer()
      src = makeStandardSwitch(TcpAutoAddress)
    await src.start()
    defer:
      await src.stop()
      await stall.stop()

    let dialer = Dialer.new(
      src.peerInfo.peerId,
      src.connManager,
      src.peerStore,
      src.transports,
      src.ms,
      dialTimeout = 1.seconds,
    )
    let peerId = PeerId.random(rng()).tryGet()

    # Twice: the second dial only gets its turn if the first freed the peer's
    # dial lock, which a dial that hangs never does.
    for _ in 0 .. 1:
      expect DialFailedError:
        await dialer.connect(peerId, @[stall.address]).wait(10.seconds)

  asyncTest "A stalling address-only dial does not block another one":
    let
      stall = startStallServer()
      src = makeStandardSwitch(TcpAutoAddress)
      dst = makeStandardSwitch(TcpAutoAddress)
    await src.start()
    await dst.start()

    let dialer = Dialer.new(
      src.peerInfo.peerId,
      src.connManager,
      src.peerStore,
      src.transports,
      src.ms,
      dialTimeout = 30.seconds,
    )

    # Dials with no peer id shared one lock keyed on `default(PeerId)`, so the
    # stalling one held up every other address the node dialed.
    let stalling = dialer.connect(stall.address, allowUnknownPeerId = true)
    defer:
      await noCancel stalling.cancelAndWait()
      await allFutures(src.stop(), dst.stop())
      await stall.stop()

    await sleepAsync(100.milliseconds) # let the stalling dial take its lock

    let dialed = await dialer
      .connect(dst.peerInfo.addrs[0], allowUnknownPeerId = true)
      .wait(5.seconds)
    check dialed == dst.peerInfo.peerId
