# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, std/[sequtils, tables]
import ../../libp2p/[switch, connmanager, peerinfo, stream/connection]
import ../tools/[unittest, futures, switch_builder]

proc newWatermarkSwitch(
    lowWater: int,
    highWater: int,
    gracePeriod: Duration = 0.seconds,
    silencePeriod: Duration = 0.seconds,
    outboundBonus: int = 0,
    decayResolution: Duration = 1.minutes,
    maxConnections: int = 0,
): Switch {.raises: [LPError].} =
  var builder = makeStandardSwitchBuilder("", TransportType.QUIC)
    .withWatermarkPolicy(lowWater, highWater, gracePeriod, silencePeriod)
    .withPeerScoring(
      PeerScoring(outboundBonus: outboundBonus, decayResolution: decayResolution)
    )
  if maxConnections > 0:
    builder = builder.withMaxConnections(maxConnections)
  builder.build()

proc newSwitch(): Switch {.raises: [LPError].} =
  makeStandardSwitch("", TransportType.QUIC)

proc newSwitches(count: int): seq[Switch] {.raises: [LPError].} =
  (0 ..< count).mapIt(newSwitch())

template startAndDeferStop(switches: seq[Switch]): untyped =
  await allFuturesRaising(switches.mapIt(it.start()))
  defer:
    await allFuturesRaising(switches.mapIt(it.stop()))

proc connect(dialer, listener: Switch) {.async.} =
  await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)
  # short wait between connects
  await sleepAsync(5.millis)

proc peerCount(s: Switch): int =
  s.connManager.getConnections().len

suite "Connection Manager Watermark/Scoring Component":
  teardown:
    checkTrackers()

  asyncTest "watermark trims node down to lowWater":
    # peers[0] is the oldest peer, the first to be trimmed.
    const
      lowWater = 2
      highWater = 4
    let node = newWatermarkSwitch(lowWater, highWater)
    # one peer over highWater so the last dial triggers the only trim cycle
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    for peer in peers:
      await connect(peer, node)

    # the trim settles at lowWater with peers[0] pruned as the oldest peer
    checkUntilTimeout:
      node.peerCount == lowWater

    check not node.isConnected(peers[0].peerInfo.peerId)

  asyncTest "grace period exempts newly connected peers":
    const
      lowWater = 1
      highWater = 2
    # long grace period so every peer is too young to be trimmed
    let node = newWatermarkSwitch(lowWater, highWater, gracePeriod = 1.hours)
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    for peer in peers:
      await connect(peer, node)

    # the trim fires but finds no eligible candidates, so all peers stay connected
    await sleepAsync(200.millis)
    check node.peerCount == peers.len

  asyncTest "grace period exempts recent peers but trims older ones":
    # peers[0] connects first and is past the grace period when the trim runs.
    # peers[1] and peers[2] are still within the grace period, so the trim skips them.
    # only peers[0] can be pruned, so the count settles above lowWater.
    const
      lowWater = 1
      highWater = 2
      gracePeriod = 1.seconds
    let node = newWatermarkSwitch(lowWater, highWater, gracePeriod = gracePeriod)
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    # peers[0] moves past the grace period before the other peers connect
    await connect(peers[0], node)
    await sleepAsync(gracePeriod + 500.millis)

    # peers[1] and peers[2] connect within the grace period, peers[2] triggers the trim
    await connect(peers[1], node)
    await connect(peers[2], node)

    # the trim prunes the peer past the grace period and skips the two within it
    checkUntilTimeout:
      node.peerCount == 2

    check:
      not node.isConnected(peers[0].peerInfo.peerId)
      node.isConnected(peers[1].peerInfo.peerId)
      node.isConnected(peers[2].peerInfo.peerId)

  asyncTest "protected peer survives trim":
    # peers[0] is the oldest peer, the first to be trimmed.
    # protection keeps it connected through the trim.
    const
      lowWater = 2
      highWater = 3
    let node = newWatermarkSwitch(lowWater, highWater)
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    for peer in peers[0 ..< ^1]:
      await connect(peer, node)

    # protect peers[0] before the trim-triggering dial
    node.connManager.protect(peers[0].peerInfo.peerId, "keep")

    await connect(peers[^1], node)

    # the trim settles at lowWater with peers[0] still connected
    checkUntilTimeout:
      node.peerCount == lowWater

    check:
      node.isConnected(peers[0].peerInfo.peerId)

  asyncTest "higher-scored peer survives trim":
    # peers[0] is the oldest peer, the first to be trimmed.
    # a high static score keeps it connected through the trim.
    const
      lowWater = 2
      highWater = 3
    let node = newWatermarkSwitch(lowWater, highWater)
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    await connect(peers[0], node)
    # give peers[0] a high static score before the trim-triggering dial
    node.connManager.tagPeer(peers[0].peerInfo.peerId, "important", 500)
    for peer in peers[1 .. ^1]:
      await connect(peer, node)

    # the trim settles at lowWater with peers[0] still connected
    checkUntilTimeout:
      node.peerCount == lowWater

    check node.isConnected(peers[0].peerInfo.peerId)

  asyncTest "outbound peer survives trim over inbound peers":
    # peers[0] is the oldest peer, the first to be trimmed.
    # the node dialed it, so outboundBonus keeps it connected through the trim.
    const
      lowWater = 2
      highWater = 3
    let node = newWatermarkSwitch(lowWater, highWater, outboundBonus = 500)
    let peers = newSwitches(highWater + 1)
    let all = @[node] & peers

    startAndDeferStop(all)

    # the node dials peers[0], so that connection is outbound from the node
    await connect(node, peers[0])
    # the rest dial the node, so those connections are inbound on the node
    for peer in peers[1 .. ^1]:
      await connect(peer, node)

    # the trim settles at lowWater with peers[0] still connected
    checkUntilTimeout:
      node.peerCount == lowWater

    check node.isConnected(peers[0].peerInfo.peerId)
