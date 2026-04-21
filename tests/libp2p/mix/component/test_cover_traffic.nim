# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results
import
  ../../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/cover_traffic,
    protocols/mix/delay_strategy,
    protocols/mix/serialization,
    protocols/mix/mix_node,
    protocols/mix/spam_protection,
    peerid,
    multiaddress,
    switch,
    builders,
  ]

import metrics
import ../../../../libp2p/protocols/mix/mix_metrics
import ../../../tools/[lifecycle, unittest, crypto]
import ../[utils, spam_protection_impl]

suite "Cover Traffic - Integration":
  asyncTeardown:
    checkTrackers()

  asyncTest "buildCoverPacket produces valid Sphinx that can be processed by each hop":
    let nodes = await setupMixNodes(5)
    startAndDeferStop(nodes)

    let node = nodes[0]
    let buildRes = node.buildCoverPacket()
    check buildRes.isOk
    let built = buildRes.get()

    check built.packet.len == PacketSize
    check built.firstHopPeerId != node.switch.peerInfo.peerId

    # Verify the packet can be deserialized as a valid Sphinx packet
    let sphinxPacket = SphinxPacket.deserialize(built.packet)
    check sphinxPacket.isOk

  asyncTest "cover packet traverses network and is silently discarded at exit":
    let nodes = await setupMixNodes(
      5, delayStrategy = Opt.some(DelayStrategy(FixedDelayStrategy(delay: 0)))
    )
    startAndDeferStop(nodes)

    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDuration = 100.seconds, useInternalEpochTimer = false
    )

    ct.setCoverPacketBuilder(
      proc(): Result[CoverPacketBuild, string] {.gcsafe, raises: [].} =
        nodes[0].buildCoverPacket()
    )
    ct.setCoverPacketSender(
      proc(
          peerId: PeerId, multiAddr: MultiAddress, packet: seq[byte]
      ): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
        return await nodes[0].sendCoverPacket(peerId, multiAddr, packet)
    )
    ct.onEpochChange(1)

    let coverReceivedBefore = mix_cover_received.value()

    await ct.emitCoverPacket()
    check ct.slotPool.coverClaimed == 1

    # Verify cover packet was received at exit and silently discarded
    checkUntilTimeout:
      mix_cover_received.value() > coverReceivedBefore

  asyncTest "slot exhaustion blocks local send, epoch reset unblocks":
    let nodes = await setupMixNodes(5)
    startAndDeferStop(nodes)

    let ct = ConstantRateCoverTraffic.new(totalSlots = 2, useInternalEpochTimer = false)
    ct.onEpochChange(1)
    nodes[0].coverTraffic = Opt.some(CoverTraffic(ct))

    let (destNode, _) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let incoming = newAsyncQueue[seq[byte]]()

    # First send succeeds (claims 1 of 2 slots)
    let res1 = await nodes[0].anonymizeLocalProtocolSend(
      incoming, @[1.byte], "/test/1.0.0", destNode.toMixDestination(), 0
    )
    check res1.isOk

    # Second send succeeds (claims 2 of 2 slots)
    let res2 = await nodes[0].anonymizeLocalProtocolSend(
      incoming, @[2.byte], "/test/1.0.0", destNode.toMixDestination(), 0
    )
    check res2.isOk

    # Third send fails — slots exhausted
    let res3 = await nodes[0].anonymizeLocalProtocolSend(
      incoming, @[3.byte], "/test/1.0.0", destNode.toMixDestination(), 0
    )
    check res3.isErr
    check res3.error == "No slots available in current epoch"

    # Epoch reset unblocks
    ct.onEpochChange(2)
    let res4 = await nodes[0].anonymizeLocalProtocolSend(
      incoming, @[4.byte], "/test/1.0.0", destNode.toMixDestination(), 0
    )
    check res4.isOk

  asyncTest "MixProtocol wires SpamProtection epoch changes to cover traffic":
    let nodeInfos = MixNodeInfo.generateRandomMany(5)
    let mixNodeInfo = nodeInfos[0]
    let switch =
      createSwitch(mixNodeInfo.multiAddr, Opt.some(mixNodeInfo.libp2pPrivKey))

    let sp = newRateLimitSpamProtection(100)
    let ct = ConstantRateCoverTraffic.new(totalSlots = 5)

    discard MixProtocol.new(
      mixNodeInfo,
      switch,
      spamProtection = Opt.some(SpamProtection(sp)),
      delayStrategy = Opt.some(DelayStrategy(NoSamplingDelayStrategy.new(rng()))),
      coverTraffic = Opt.some(CoverTraffic(ct)),
    )

    # Exhaust slots
    for _ in 0 ..< 5:
      discard ct.slotPool.claimSlot()
    check ct.slotPool.availableSlots == 0

    # SpamProtection epoch change should propagate to cover traffic
    sp.notifyEpochChange(42)
    check ct.slotPool.epoch == 42
    check ct.slotPool.availableSlots == 5

  asyncTest "no cover traffic configured — send works without slot claiming":
    let nodes = await setupMixNodes(5)
    startAndDeferStop(nodes)

    check nodes[0].coverTraffic.isNone

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let incoming = newAsyncQueue[seq[byte]]()
    let sendRes = await nodes[0].anonymizeLocalProtocolSend(
      incoming, @[1.byte, 2, 3], "/test/1.0.0", destNode.toMixDestination(), 0
    )
    check sendRes.isOk

    let receivedMsg = await nrProto.receivedMessages.get().wait(2.seconds)
    check receivedMsg.data.len > 0
