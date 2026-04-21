# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import results
import ../../../libp2p/protocols/mix/[cover_traffic, serialization, spam_protection]
import ../../../libp2p/[multiaddress, peerid]
import ../../../libp2p/crypto/[crypto, secp]
import ../../tools/[unittest, crypto]

proc makePeerInfo(): (PeerId, MultiAddress) =
  let kp = SkKeyPair.random(rng()[])
  let pubKeyProto = PublicKey(scheme: Secp256k1, skkey: kp.pubkey)
  let pid = PeerId.init(pubKeyProto).expect("PeerId init")
  let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/5000").tryGet()
  (pid, ma)

proc mockBuildCoverPacket(): BuildCoverPacketProc =
  let (pid, ma) = makePeerInfo()
  return proc(): Result[CoverPacketBuild, string] {.gcsafe, raises: [].} =
    ok(
      CoverPacketBuild(
        packet: newSeq[byte](PacketSize),
        firstHopPeerId: pid,
        firstHopAddr: ma,
        proofToken: @[0x42.byte],
      )
    )

proc mockBuildCoverPacketFailing(): BuildCoverPacketProc =
  return proc(): Result[CoverPacketBuild, string] {.gcsafe, raises: [].} =
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
    let (pid, ma) = makePeerInfo()
    discard pool.claimSlot()
    discard pool.claimSlotForCover()
    pool.addPacket(
      CoverPacket(packet: @[1.byte], firstHopPeerId: pid, firstHopAddr: ma)
    )
    pool.beginEpoch(42)
    check:
      pool.epoch == 42
      pool.availableSlots == 10
      pool.coverClaimed == 0
      pool.nonCoverClaimed == 0
      pool.queuedCount == 0 # Stale packets cleared on epoch change

  test "claimSlot discards a pre-built packet and returns its proof token":
    let pool = SlotPool.new(10)
    let (pid, ma) = makePeerInfo()
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
    let pool = SlotPool.new(3)
    check pool.claimSlot().success == true
    check pool.claimSlotForCover() == true
    check pool.claimSlot().success == true
    check pool.claimSlot().success == false
    check pool.claimSlotForCover() == false
    check:
      pool.nonCoverClaimed == 2
      pool.coverClaimed == 1

suite "ConstantRateCoverTraffic":
  test "emission sends packet and claims slot":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDuration = 1.seconds)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check sentPackets[].len == 1
    check ct.slotPool.coverClaimed == 1

  test "emission stops when exhausted, resumes after epoch change":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(totalSlots = 1, epochDuration = 1.seconds)
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

  test "build failure does not crash emission and returns slot":
    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDuration = 1.seconds)
    ct.setCoverPacketBuilder(mockBuildCoverPacketFailing())
    ct.setCoverPacketSender(mockSendCoverPacket(new seq[seq[byte]]))
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check ct.slotPool.coverClaimed == 0 # Slot returned on build failure

  test "send failure does not crash emission":
    let ct = ConstantRateCoverTraffic.new(totalSlots = 10, epochDuration = 1.seconds)
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacketFailing())
    ct.onEpochChange(1)

    waitFor ct.emitCoverPacket()
    check ct.slotPool.coverClaimed == 1

  asyncTest "start and stop":
    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDuration = 100.seconds, useInternalEpochTimer = false
    )
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(new seq[seq[byte]]))
    ct.onEpochChange(1)

    await ct.start()
    check ct.isRunning == true

    await ct.stop()
    check ct.isRunning == false

suite "CoverTraffic Pre-computation":
  test "pre-built packets used before on-demand, falls back when empty":
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDuration = 1.seconds, enablePrecomputation = true
    )
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.onEpochChange(1)

    let (pid, ma) = makePeerInfo()
    let prebuiltPacket = @[0xAA.byte]
    ct.slotPool.addPacket(
      CoverPacket(packet: prebuiltPacket, firstHopPeerId: pid, firstHopAddr: ma)
    )

    # First: uses pre-built
    waitFor ct.emitCoverPacket()
    check sentPackets[][0] == prebuiltPacket

    # Second: queue empty, falls back to on-demand
    waitFor ct.emitCoverPacket()
    check sentPackets[][1].len == PacketSize

  test "epoch change clears stale cover packets":
    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 10, epochDuration = 1.seconds, enablePrecomputation = true
    )
    let (pid, ma) = makePeerInfo()
    ct.slotPool.addPacket(
      CoverPacket(packet: @[0xAA.byte], firstHopPeerId: pid, firstHopAddr: ma)
    )
    ct.onEpochChange(2)
    check ct.slotPool.queuedCount == 0 # Stale packets cleared

  test "stale prebuilt proof consumes only one slot":
    ## Verify that when a prebuilt proof is stale, only ONE slot is consumed
    ## (the initial claimSlotForCover), not two.
    let sentPackets = new seq[seq[byte]]
    sentPackets[] = @[]

    let ct = ConstantRateCoverTraffic.new(
      totalSlots = 2, epochDuration = 1.seconds, enablePrecomputation = true
    )
    ct.setCoverPacketBuilder(mockBuildCoverPacket())
    ct.setCoverPacketSender(mockSendCoverPacket(sentPackets))
    ct.setProofTokenValidator(
      proc(token: seq[byte]): bool {.gcsafe, raises: [].} =
        false # All proofs are stale
    )
    ct.onEpochChange(1)

    let (pid, ma) = makePeerInfo()
    ct.slotPool.addPacket(
      CoverPacket(
        packet: @[0xAA.byte],
        firstHopPeerId: pid,
        firstHopAddr: ma,
        proofToken: @[0x01.byte],
      )
    )

    waitFor ct.emitCoverPacket()
    # Stale proof: should rebuild on-demand but consume only 1 slot
    check ct.slotPool.coverClaimed == 1
    check sentPackets[].len == 1
    # The sent packet should be on-demand (PacketSize), not the prebuilt one
    check sentPackets[][0].len == PacketSize

    # Second emission should still succeed (1 of 2 slots used)
    waitFor ct.emitCoverPacket()
    check ct.slotPool.coverClaimed == 2
    check sentPackets[].len == 2

suite "CoverTraffic DoS Protection Independence":
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
