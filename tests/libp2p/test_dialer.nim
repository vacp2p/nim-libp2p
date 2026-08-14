# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, sequtils, results
import ../../libp2p/[builders, peerstore, switch]
import ../tools/[unittest, futures, switch_builder, crypto, multiaddress, stall_server]

proc replaceIdentifyHandler(sw: Switch, handler: LPProtoHandler) =
  for holder in sw.ms.handlers:
    if IdentifyCodec in holder.protos:
      holder.protocol.handler = handler

proc stallIdentify(sw: Switch) =
  ## Never answer identify, so only the identify budget can end the dial.
  proc stall(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    await stream.join()

  sw.replaceIdentifyHandler(stall)

proc stallAfterIdentify(sw: Switch) =
  ## Answer identify, then hold the stream open so no EOF ever arrives.
  let pusher = IdentifyPush.new()
  proc hold(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      await pusher.push(sw.peerInfo, stream)
    except LPStreamError:
      discard
    await stream.join()

  sw.replaceIdentifyHandler(hold)

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

    await stall.waitAccepted().wait(5.seconds)

    let dialed = await dialer
      .connect(dst.peerInfo.addrs[0], allowUnknownPeerId = true)
      .wait(5.seconds)
    check dialed == dst.peerInfo.peerId

  asyncTest "A remote that never answers identify gives up at the dial timeout":
    let
      src = makeStandardSwitch(TcpAutoAddress)
      dst = makeStandardSwitch(TcpAutoAddress)
    await src.start()
    await dst.start()
    dst.stallIdentify()
    defer:
      await allFutures(src.stop(), dst.stop())

    let dialer = Dialer.new(
      src.peerInfo.peerId,
      src.connManager,
      src.peerStore,
      src.transports,
      src.ms,
      dialTimeout = 1.seconds,
    )

    # Twice: the second dial only gets its turn if the first freed the peer's
    # dial lock, which identify holds for as long as the connection lives.
    for _ in 0 .. 1:
      expect DialFailedError:
        await dialer
          .connect(
            dst.peerInfo.peerId,
            dst.peerInfo.addrs,
            forceDial = true,
            reuseConnection = false,
          )
          .wait(10.seconds)

  asyncTest "A remote that never closes the identify stream frees the dial":
    let
      src = makeStandardSwitch(TcpAutoAddress)
      dst = makeStandardSwitch(TcpAutoAddress)
    await src.start()
    await dst.start()
    dst.stallAfterIdentify()
    defer:
      await allFutures(src.stop(), dst.stop())

    let dialer = Dialer.new(
      src.peerInfo.peerId,
      src.connManager,
      src.peerStore,
      src.transports,
      src.ms,
      dialTimeout = 1.seconds,
    )

    # Twice: the second dial gets its turn only if the first freed the lock.
    for _ in 0 .. 1:
      let dial = dialer.connect(
        dst.peerInfo.peerId,
        dst.peerInfo.addrs,
        forceDial = true,
        reuseConnection = false,
      )
      # `join`, not `wait`: a cancel waits out a dial parked in `noCancel`.
      if not await dial.join().withTimeout(IdentifyCloseTimeout * 2):
        fail()
        return
      await dial
