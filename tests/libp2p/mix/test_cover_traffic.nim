# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import results
import ../../../libp2p/protocols/mix/[cover_traffic, serialization, spam_protection]
import ../../../libp2p/[multiaddress, peerid]
import ../../../libp2p/crypto/[crypto, secp]
import ../../tools/[unittest, crypto]

proc makePeerId(): PeerId =
  let kp = SkKeyPair.random(rng()[])
  let pubKeyProto = PublicKey(scheme: Secp256k1, skkey: kp.pubkey)
  PeerId.init(pubKeyProto).expect("PeerId init")

proc makeMultiAddr(port: int): MultiAddress =
  MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()

proc mockBuildCoverPacket(): BuildCoverPacketProc =
  let pid = makePeerId()
  let ma = makeMultiAddr(5000)
  return proc(): Result[
      tuple[
        packet: seq[byte],
        firstHopPeerId: PeerId,
        firstHopAddr: MultiAddress,
        proofToken: seq[byte],
      ],
      string,
  ] {.gcsafe, raises: [].} =
    ok(
      (
        packet: newSeq[byte](PacketSize),
        firstHopPeerId: pid,
        firstHopAddr: ma,
        proofToken: @[0x42.byte],
      )
    )

proc mockBuildCoverPacketFailing(): BuildCoverPacketProc =
  return proc(): Result[
      tuple[
        packet: seq[byte],
        firstHopPeerId: PeerId,
        firstHopAddr: MultiAddress,
        proofToken: seq[byte],
      ],
      string,
  ] {.gcsafe, raises: [].} =
    err("mock build failure")

proc mockSendCoverPacket(sentPackets: ref seq[seq[byte]]): SendCoverPacketProc =
  return proc(
      peerId: PeerId, multiAddr: MultiAddress, packet: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
    sentPackets[].add(packet)
    return ok()

proc mockSendCoverPacketFailing(): SendCoverPacketProc =
  return proc(
      peerId: PeerId, multiAddr: MultiAddress, packet: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
    return err("mock send failure")

suite "SlotPool":
  test "exhaustion returns false for both claim types":
    let pool = SlotPool.new(2)
    check pool.claimSlot().success == true
    check pool.claimSlotForCover() == true
    check pool.claimSlot().success == false
    check pool.claimSlotForCover() == false

  test "beginEpoch refills pool and clears stale packets":
    let pool = SlotPool.new(10)
    let pid = makePeerId()
    let ma = makeMultiAddr(5000)
    discard pool.claimSlot()
    discard pool.claimSlotForCover()
    pool.addPacket(
      CoverPacket(packet: @[1.byte], firstHopPeerId: pid, firstHopAddr: ma)
    )
    pool.beginEpoch(42)
    check:
      pool.epoch == 42
      pool.availableSlots == 10
      pool.coverEmitted == 0
      pool.nonCoverClaimed == 0
      pool.queuedCount == 0 # Stale packets cleared on epoch change
      pool.pendingCount == 0

  test "claimSlot discards a pre-built packet and returns its proof token":
    let pool = SlotPool.new(10)
    let pid = makePeerId()
    let ma = makeMultiAddr(5000)
    pool.addPacket(
      CoverPacket(
        packet: @[0xAA.byte],
        firstHopPeerId: pid,
        firstHopAddr: ma,
        proofToken: @[0x01.byte],
      )
    )
    pool.addPacket(
      CoverPacket(
        packet: @[0xBB.byte],
        firstHopPeerId: pid,
        firstHopAddr: ma,
        proofToken: @[0x02.byte],
      )
    )
    let claim = pool.claimSlot()
    check claim.success == true
    check claim.reclaimedToken == @[0x01.byte]
    check pool.queuedCount == 1
    check pool.dequeue().get().packet == @[0xBB.byte]

  test "mixed traffic draws from same pool":
    let pool = SlotPool.new(5)
    check pool.claimSlot().success == true
    check pool.claimSlotForCover() == true
    check pool.claimSlot().success == true
    check pool.claimSlotForCover() == true
    check pool.claimSlot().success == true
    check pool.claimSlot().success == false
    check pool.claimSlotForCover() == false
    check:
      pool.nonCoverClaimed == 3
      pool.coverEmitted == 2

suite "ConstantRateCoverTraffic":
  test "emission sends packet and claims slot":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDurationSec = 1.0)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 1
    check ct.slotPool.coverEmitted == 1

  test "emission stops when exhausted, resumes after epoch change":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(totalSlots = 1, epochDurationSec = 1.0)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 1

    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 1

    ct.onEpochChange(2)
    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 2

  test "build failure does not crash emission":
    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDurationSec = 1.0)
    ct.setCoverPacketBuilder(mockBuildCoverPacketFailing())
    ct.setCoverPacketSender(mockSendCoverPacket(new seq[seq[byte]]))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check ct.slotPool.coverEmitted == 1

  test "send failure does not crash emission":
    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDurationSec = 1.0)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacketFailing())
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check ct.slotPool.coverEmitted == 1

suite "CoverTraffic Pre-computation":
  test "pre-built packets used before on-demand, falls back when empty":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDurationSec = 1.0, enablePrecomputation = true
    )
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    let pid = makePeerId()
    let ma = makeMultiAddr(6000)
    ct.slotPool.addPacket(
      CoverPacket(packet: @[0xAA.byte], firstHopPeerId: pid, firstHopAddr: ma)
    )

    # First: uses pre-built
    waitFor ct.emitCoverPacket()
    check sentPackets[][0] == @[0xAA.byte]

    # Second: queue empty, falls back to on-demand
    waitFor ct.emitCoverPacket()
    check sentPackets[][1].len == PacketSize

  test "epoch change clears stale cover packets":
    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDurationSec = 1.0, enablePrecomputation = true
    )
    let pid = makePeerId()
    let ma = makeMultiAddr(6000)
    ct.slotPool.addPacket(
      CoverPacket(packet: @[0xAA.byte], firstHopPeerId: pid, firstHopAddr: ma)
    )
    ct.onEpochChange(2)
    check ct.slotPool.queuedCount == 0 # Stale packets cleared
    check ct.slotPool.pendingCount == 0

suite "CoverTraffic DoS Protection Independence":
  test "works without SpamProtection using defaults":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new()
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 1

  test "SpamProtection epoch change propagates to cover traffic":
    let sp = SpamProtection(proofSize: 0)
    let ct = ConstantRateCoverTraffic.new(totalSlots = 5)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(new seq[seq[byte]]))

    sp.registerOnEpochChange(
      proc(epoch: uint64) {.gcsafe, raises: [].} =
        ct.onEpochChange(epoch)
    )

    for _ in 0 ..< 5:
      discard ct.slotPool.claimSlot()
    check ct.slotPool.availableSlots == 0

    sp.notifyEpochChange(10)
    check:
      ct.slotPool.epoch == 10
      ct.slotPool.availableSlots == 5

suite "CoverTraffic Lifecycle":
  asyncTest "start and stop":
    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDurationSec = 100.0, useInternalEpochTimer = false
    )
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(new seq[seq[byte]]))
    ct.onEpochChange(1)

    asyncSpawn ct.start()
    checkUntilTimeout:
      ct.isRunning == true

    await ct.stop()
    check ct.isRunning == false
