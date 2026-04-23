# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable cover traffic interface and strategies for the Mix Protocol.
##
## Cover traffic ensures sender unobservability by emitting dummy Sphinx packets
## at a constant rate, making it impossible for an observer to distinguish cover
## traffic from locally originated messages.
##
## See Mix Cover Traffic specification sections 3-7.

import std/deques
import chronicles, chronos, results, metrics
import ../../[multiaddress, peerid]
import ../../utils/heartbeat
import ./mix_metrics, ./sphinx

logScope:
  topics = "libp2p mix covertraffic"

# Callback types injected by MixProtocol to avoid circular dependency.
# CoverTraffic lives in a separate module and cannot import MixProtocol
# (that would create a circular import). The callbacks are the only way
# to break this cycle while letting CoverTraffic build and send packets
# through MixProtocol's infrastructure (nodePool, sphinx, spam protection).
type
  CoverPacketBuild* = object
    packet*: seq[byte]
    firstHopPeerId*: PeerId
    firstHopAddr*: MultiAddress
    proofToken*: seq[byte]

  BuildCoverPacketProc* =
    proc(): Result[CoverPacketBuild, string] {.gcsafe, raises: [].}

  SendCoverPacketProc* = proc(
    peerId: PeerId, multiAddr: MultiAddress, packet: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: [CancelledError]).}

type
  CoverPacket* = object
    packet*: seq[byte]
    firstHopPeerId*: PeerId
    firstHopAddr*: MultiAddress
    proofToken*: seq[byte] ## Opaque token from spam protection proof generation

  ClaimResult* = object
    success*: bool
    reclaimedToken*: seq[byte] ## Proof token from discarded cover packet (empty if none)

type SlotPool* = ref object
  ## Manages the R-slot budget per epoch. All traffic types (cover, local
  ## origination, forwarding) draw from the same pool.
  epoch*: uint64
  totalSlots: int
  coverQueue: Deque[CoverPacket]
  coverClaimed*: int
  nonCoverClaimed*: int

proc new*(T: typedesc[SlotPool], totalSlots: int): T =
  doAssert totalSlots > 0, "SlotPool totalSlots must be greater than zero"
  T(epoch: 0, totalSlots: totalSlots, coverQueue: initDeque[CoverPacket]())

proc beginEpoch*(pool: SlotPool, epoch: uint64) =
  ## Clear stale cover packets and refill slots for the new epoch.
  ## Precomputed packets from the previous epoch are discarded because
  ## their proofs belong to the old epoch.
  pool.epoch = epoch
  pool.coverQueue = initDeque[CoverPacket]()
  pool.coverClaimed = 0
  pool.nonCoverClaimed = 0

func availableSlots*(pool: SlotPool): int {.inline.} =
  pool.totalSlots - pool.coverClaimed - pool.nonCoverClaimed

func hasAvailableSlots*(pool: SlotPool): bool {.inline.} =
  pool.availableSlots > 0

proc claimSlotForCover*(pool: SlotPool): bool =
  if not pool.hasAvailableSlots():
    return false
  pool.coverClaimed += 1
  true

proc claimSlot*(pool: SlotPool): ClaimResult =
  ## Claim a slot for non-cover use. Discards one pre-built cover packet
  ## and returns its proof token for potential reuse (Mix Cover Traffic spec §5.2).
  if not pool.hasAvailableSlots():
    return ClaimResult(success: false)

  pool.nonCoverClaimed += 1
  var token: seq[byte]
  if pool.coverQueue.len > 0:
    let discarded = pool.coverQueue.popFirst()
    token = discarded.proofToken
  ClaimResult(success: true, reclaimedToken: token)

func totalSlots*(pool: SlotPool): int {.inline.} =
  pool.totalSlots

proc addPacket*(pool: SlotPool, pkt: CoverPacket) =
  pool.coverQueue.addLast(pkt)

func queuedCount*(pool: SlotPool): int {.inline.} =
  pool.coverQueue.len

proc dequeue*(pool: SlotPool): Opt[CoverPacket] {.inline.} =
  if pool.coverQueue.len == 0:
    return Opt.none(CoverPacket)
  Opt.some(pool.coverQueue.popFirst())

type
  ValidateProofTokenProc* = proc(token: seq[byte]): bool {.gcsafe, raises: [].}
    ## Callback to check if a prebuilt proof is still valid (e.g., Merkle root
    ## still in the acceptable window). Returns true if valid, false if stale.

  ReclaimProofTokenProc* = proc(token: seq[byte]) {.gcsafe, raises: [].}
    ## Callback to return a proof token for reuse when a prebuilt cover packet
    ## is discarded (e.g., due to stale Merkle root).

  CoverTraffic* = ref object of RootObj
    ## Abstract base to allow alternate emission strategies (e.g. Poisson-Rate).
    ## MixProtocol injects packet building and sending via callback procs.
    slotPool*: SlotPool
    buildPacket: BuildCoverPacketProc
    sendPacket: SendCoverPacketProc
    validateProofToken: ValidateProofTokenProc
    reclaimProofToken: ReclaimProofTokenProc

method start*(ct: CoverTraffic) {.base, async: (raises: [CancelledError]).} =
  raiseAssert "start must be implemented by concrete cover traffic types"

method stop*(ct: CoverTraffic) {.base, async: (raises: []).} =
  raiseAssert "stop must be implemented by concrete cover traffic types"

method onEpochChange*(ct: CoverTraffic, epoch: uint64) {.base, gcsafe, raises: [].} =
  ct.slotPool.beginEpoch(epoch)

method onCoverReceived*(ct: CoverTraffic) {.base, gcsafe, raises: [].} =
  ## Diagnostics hook when a cover packet loops back (Mix Cover Traffic spec §11.2).
  discard

proc setCoverPacketBuilder*(ct: CoverTraffic, builder: BuildCoverPacketProc) =
  ct.buildPacket = builder

proc setProofTokenValidator*(ct: CoverTraffic, validator: ValidateProofTokenProc) =
  ct.validateProofToken = validator

proc setProofTokenReclaimer*(ct: CoverTraffic, reclaimer: ReclaimProofTokenProc) =
  ct.reclaimProofToken = reclaimer

proc setCoverPacketSender*(ct: CoverTraffic, sender: SendCoverPacketProc) =
  ct.sendPacket = sender

type ConstantRateCoverTraffic* = ref object of CoverTraffic
  ## Emits cover packets at a fixed interval derived from
  ## `scaledSlots = max(1, floor(f * R))`, giving `((1 + L) * P) / scaledSlots`
  ## seconds (with a 1 ms lower bound), where f is the `cover_rate_fraction`.
  ## RECOMMENDED as the default strategy (Mix Cover Traffic spec §7.1).
  emissionInterval: Duration
  epochDuration: Duration
  coverRateFraction: float
  precomputeTarget: int
  enablePrecomputation: bool
  precomputeBatchSize: int
  emissionLoop: Future[void]
  precomputeLoop: Future[void]
  epochTimerLoop: Future[void]
  emissionEpochEvent: AsyncEvent
  precomputeEpochEvent: AsyncEvent
  useInternalEpochTimer: bool
  running: bool

proc new*(
    T: typedesc[ConstantRateCoverTraffic],
    totalSlots: int = 100,
    epochDuration: Duration = 60.seconds,
    coverRateFraction: float = 0.7,
    enablePrecomputation: bool = false,
    precomputeBatchSize: int = 0,
    useInternalEpochTimer: bool = true,
): T =
  ## Parameters:
  ##   totalSlots: R (rate limit budget per epoch)
  ##   epochDuration: P (epoch duration)
  ##   coverRateFraction: f ∈ (0.0, 1.0], scales the cover emission rate
  ##     relative to the maximum safe rate R / ((1+L) * P).
  ##     Default (0.7) reserves ~30% headroom for forwarding variance.
  ##   enablePrecomputation: whether to pre-build cover packets in batches
  ##   precomputeBatchSize: packets per batch (0 = auto: f * R / (1+L) / 10)
  ##   useInternalEpochTimer: false when SpamProtection provides OnEpochChange
  doAssert totalSlots > 0, "totalSlots (R) must be positive"
  doAssert epochDuration > Duration.default, "epochDuration (P) must be positive"
  doAssert coverRateFraction > 0.0 and coverRateFraction <= 1.0,
    "coverRateFraction (f) must be in (0.0, 1.0]"

  # Effective cover budget after `cover_rate_fraction` scaling: floor(f * R).
  # Clamped to at least 1 so very small f values don't produce a zero divisor.
  let scaledSlots = max(1, (totalSlots.float * coverRateFraction).int)

  # Time between consecutive cover emissions: ((1 + L) * P) / scaledSlots,
  # clamped to at least 1 ms to guard against overly tight scheduling for large R.
  # Approximates the continuous rate ((1 + L) * P) / (f * R); differs when
  # floor(f * R) < 1 or when f * R is non-integer.
  let emissionInterval =
    max(1.milliseconds, epochDuration * (1 + PathLength) div scaledSlots)

  # Expected cover emissions per epoch at equilibrium: scaledSlots / (1 + L),
  # clamped to at least 1 packet. The remaining slots in R are consumed by
  # forwarding and local origination. Approximates (f * R) / (1 + L) with
  # integer floor applied at each step.
  let precomputeTarget = max(1, scaledSlots div (1 + PathLength))

  # Default batch size = 10% of precomputeTarget (at least 1), so pre-computation
  # spreads across ~10 batches per epoch.
  let batchSize =
    if precomputeBatchSize > 0:
      precomputeBatchSize
    else:
      max(1, precomputeTarget div 10)

  T(
    slotPool: SlotPool.new(totalSlots),
    emissionInterval: emissionInterval,
    epochDuration: epochDuration,
    coverRateFraction: coverRateFraction,
    precomputeTarget: precomputeTarget,
    enablePrecomputation: enablePrecomputation,
    precomputeBatchSize: batchSize,
    emissionEpochEvent: newAsyncEvent(),
    precomputeEpochEvent: newAsyncEvent(),
    useInternalEpochTimer: useInternalEpochTimer,
    running: false,
  )

proc unclaimCoverSlot(ct: ConstantRateCoverTraffic) =
  ## Return a cover slot on build failure so it can be retried within the
  ## same epoch. Send failures do NOT unclaim — the proof/messageId was
  ## already consumed and cannot be reused.
  if ct.slotPool.coverClaimed > 0:
    ct.slotPool.coverClaimed -= 1

proc buildAndSendOnDemand(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  ## Build and send a cover packet on-demand. Assumes slot is already claimed.
  let buildRes = ct.buildPacket()
  if buildRes.isErr:
    trace "Failed to build cover packet", err = buildRes.error
    mix_cover_error.inc(labelValues = ["BUILD_FAILED"])
    ct.unclaimCoverSlot()
    return

  let built = buildRes.get()
  let sendRes =
    await ct.sendPacket(built.firstHopPeerId, built.firstHopAddr, built.packet)
  if sendRes.isErr:
    debug "Failed to send cover packet", err = sendRes.error
    mix_cover_error.inc(labelValues = ["SEND_FAILED"])
  else:
    mix_cover_emitted.inc(labelValues = ["on_demand"])

proc emitCoverPacket*(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  doAssert ct.buildPacket != nil, "buildPacket callback must be set before emitting"
  doAssert ct.sendPacket != nil, "sendPacket callback must be set before emitting"

  if ct.enablePrecomputation and ct.slotPool.queuedCount > 0:
    if not ct.slotPool.claimSlotForCover():
      mix_slot_claim_rejected.inc(labelValues = ["cover"])
      return
    ct.slotPool.dequeue().withValue(pkt):
      # Check if the prebuilt proof is still valid (e.g., Merkle root not stale)
      if ct.validateProofToken != nil and pkt.proofToken.len > 0 and
          not ct.validateProofToken(pkt.proofToken):
        trace "Prebuilt cover packet has stale proof, rebuilding on-demand"
        mix_cover_error.inc(labelValues = ["STALE_PROOF"])
        # Reclaim the stale proof's messageId so it can be reused
        if ct.reclaimProofToken != nil:
          ct.reclaimProofToken(pkt.proofToken)
        await ct.buildAndSendOnDemand()
        return
      else:
        let sendRes =
          await ct.sendPacket(pkt.firstHopPeerId, pkt.firstHopAddr, pkt.packet)
        if sendRes.isErr:
          debug "Failed to send pre-built cover packet", err = sendRes.error
          mix_cover_error.inc(labelValues = ["SEND_FAILED"])
        else:
          mix_cover_emitted.inc(labelValues = ["prebuilt"])
        return

  if ct.slotPool.claimSlotForCover():
    await ct.buildAndSendOnDemand()

proc runEmissionLoop(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  var nextTick = Moment.now() + ct.emissionInterval
  while ct.running:
    if not ct.slotPool.hasAvailableSlots():
      ct.emissionEpochEvent.clear()
      await ct.emissionEpochEvent.wait()
      nextTick = Moment.now()

    let now = Moment.now()
    if now < nextTick:
      await sleepAsync(nextTick - now)

    await ct.emitCoverPacket()
    nextTick = nextTick + ct.emissionInterval

proc runPrecomputeLoop(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  ## Builds cover packets in batches and adds them to the coverQueue for the
  ## current epoch (same-epoch precomputation).
  ##
  ## Packets are built with proofs for the current epoch so their proof tokens
  ## can be reclaimed if the packet is discarded before sending.
  while ct.running:
    let currentEpoch = ct.slotPool.epoch
    let targetCount = ct.precomputeTarget
    var built = 0

    while built + ct.slotPool.queuedCount < targetCount and ct.running:
      if ct.slotPool.epoch != currentEpoch:
        trace "Epoch changed during pre-computation, aborting",
          startedEpoch = currentEpoch, currentEpoch = ct.slotPool.epoch
        break

      let batchEnd =
        min(built + ct.precomputeBatchSize, targetCount - ct.slotPool.queuedCount)
      var batchFailed = false
      while built < batchEnd:
        let buildRes = ct.buildPacket()
        if buildRes.isErr:
          debug "Pre-computation: failed to build cover packet", err = buildRes.error
          mix_cover_error.inc(labelValues = ["BUILD_FAILED"])
          batchFailed = true
          break

        let coverBuild = buildRes.get()
        ct.slotPool.addPacket(
          CoverPacket(
            packet: coverBuild.packet,
            firstHopPeerId: coverBuild.firstHopPeerId,
            firstHopAddr: coverBuild.firstHopAddr,
            proofToken: coverBuild.proofToken,
          )
        )
        built += 1
        mix_cover_precomputed.inc()
        # Yield per packet so other async tasks can proceed
        await sleepAsync(1.milliseconds)

      if batchFailed:
        break

      # Longer yield between batches
      await sleepAsync(10.milliseconds)

    trace "Pre-computation complete", epoch = currentEpoch, totalBuilt = built

    # If epoch changed during precomputation, the event was already fired
    # (via onEpochChange → fire). Don't clear+wait or we'd skip an epoch.
    if ct.slotPool.epoch != currentEpoch:
      continue

    ct.precomputeEpochEvent.clear()
    await ct.precomputeEpochEvent.wait()

proc runEpochTimer(ct: ConstantRateCoverTraffic) {.async: (raises: [CancelledError]).} =
  ## Fallback epoch timer when no SpamProtection provides OnEpochChange.
  var epochCounter: uint64 = 0
  heartbeat "Cover traffic epoch timer", ct.epochDuration, sleepFirst = true:
    epochCounter += 1
    ct.onEpochChange(epochCounter)

method onEpochChange*(
    ct: ConstantRateCoverTraffic, epoch: uint64
) {.gcsafe, raises: [].} =
  procCall CoverTraffic(ct).onEpochChange(epoch)
  ct.emissionEpochEvent.fire()
  ct.precomputeEpochEvent.fire()

method start*(ct: ConstantRateCoverTraffic) {.async: (raises: [CancelledError]).} =
  if ct.running:
    return

  doAssert ct.buildPacket != nil, "buildPacket callback must be set before start"
  doAssert ct.sendPacket != nil, "sendPacket callback must be set before start"

  ct.running = true

  ct.emissionLoop = ct.runEmissionLoop()

  if ct.enablePrecomputation:
    ct.precomputeLoop = ct.runPrecomputeLoop()

  if ct.useInternalEpochTimer:
    ct.epochTimerLoop = ct.runEpochTimer()

  debug "Cover traffic started",
    interval = ct.emissionInterval,
    precomputation = ct.enablePrecomputation,
    internalEpochTimer = ct.useInternalEpochTimer

proc cancelIfNotNil(fut: Future[void]) {.async: (raises: []).} =
  if not fut.isNil:
    await fut.cancelAndWait()

method stop*(ct: ConstantRateCoverTraffic) {.async: (raises: []).} =
  if not ct.running:
    return
  ct.running = false
  await cancelIfNotNil(ct.emissionLoop)
  await cancelIfNotNil(ct.precomputeLoop)
  await cancelIfNotNil(ct.epochTimerLoop)
  ct.emissionLoop = nil
  ct.precomputeLoop = nil
  ct.epochTimerLoop = nil
  trace "Cover traffic stopped"

func emissionInterval*(ct: ConstantRateCoverTraffic): Duration =
  ct.emissionInterval

func precomputeBatchSize*(ct: ConstantRateCoverTraffic): int =
  ct.precomputeBatchSize

func coverRateFraction*(ct: ConstantRateCoverTraffic): float =
  ct.coverRateFraction

func isRunning*(ct: ConstantRateCoverTraffic): bool =
  ct.running
