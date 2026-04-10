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
import ./mix_metrics, ./sphinx

logScope:
  topics = "libp2p mix covertraffic"

func toDuration(secs: float64): Duration =
  (secs * 1_000_000_000.0).int64.nanoseconds

const
  DefaultRateLimitBudget* = 100
  DefaultEpochDurationSec* = 60.0

# Callback types injected by MixProtocol to avoid circular dependency.
# The procs that build and send cover packets live in mix_protocol.nim
# where they have access to nodePool, sphinx, and spam protection.
type
  BuildCoverPacketProc* = proc(): Result[
    tuple[
      packet: seq[byte],
      firstHopPeerId: PeerId,
      firstHopAddr: MultiAddress,
      proofToken: seq[byte],
    ],
    string,
  ] {.gcsafe, raises: [].}

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
  pendingQueue: Deque[CoverPacket] ## Staged for next epoch
  coverEmitted*: int
  nonCoverClaimed*: int

func new*(T: typedesc[SlotPool], totalSlots: int): T =
  T(epoch: 0, totalSlots: totalSlots)

func beginEpoch*(pool: SlotPool, epoch: uint64) =
  ## Clear stale cover packets and refill slots for the new epoch.
  ## Precomputed packets from the previous epoch are discarded because
  ## their proofs belong to the old epoch.
  pool.epoch = epoch
  pool.coverQueue = initDeque[CoverPacket]()
  pool.pendingQueue = initDeque[CoverPacket]()
  pool.coverEmitted = 0
  pool.nonCoverClaimed = 0

func availableSlots*(pool: SlotPool): int =
  pool.totalSlots - pool.coverEmitted - pool.nonCoverClaimed

func hasAvailableSlots*(pool: SlotPool): bool =
  pool.availableSlots > 0

func claimSlotForCover*(pool: SlotPool): bool =
  if not pool.hasAvailableSlots():
    return false
  pool.coverEmitted += 1
  true

func claimSlot*(pool: SlotPool): ClaimResult =
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

func totalSlots*(pool: SlotPool): int =
  pool.totalSlots

func updateTotalSlots*(pool: SlotPool, r: int) =
  pool.totalSlots = r

func addPacket*(pool: SlotPool, pkt: CoverPacket) =
  pool.coverQueue.addLast(pkt)

func addPendingPacket*(pool: SlotPool, pkt: CoverPacket) =
  pool.pendingQueue.addLast(pkt)

func queuedCount*(pool: SlotPool): int =
  pool.coverQueue.len

func pendingCount*(pool: SlotPool): int =
  pool.pendingQueue.len

func dequeue*(pool: SlotPool): Opt[CoverPacket] =
  if pool.coverQueue.len == 0:
    return Opt.none(CoverPacket)
  Opt.some(pool.coverQueue.popFirst())

type
  ValidateProofTokenProc* = proc(token: seq[byte]): bool {.gcsafe, raises: [].}
    ## Callback to check if a prebuilt proof is still valid (e.g., Merkle root
    ## still in the acceptable window). Returns true if valid, false if stale.

  CoverTraffic* = ref object of RootObj
    ## Abstract base to allow alternate emission strategies (e.g. Poisson-Rate).
    ## MixProtocol injects packet building and sending via callback procs.
    slotPool*: SlotPool
    buildPacket: BuildCoverPacketProc
    sendPacket: SendCoverPacketProc
    validateProofToken: ValidateProofTokenProc

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

proc setCoverPacketSender*(ct: CoverTraffic, sender: SendCoverPacketProc) =
  ct.sendPacket = sender

type ConstantRateCoverTraffic* = ref object of CoverTraffic
  ## Emits cover packets at a fixed interval of ((1+L)*P)/R seconds.
  ## RECOMMENDED as the default strategy (Mix Cover Traffic spec §7.1).
  emissionInterval: Duration
  epochDurationSec: float64
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
    totalSlots: int = DefaultRateLimitBudget,
    epochDurationSec: float64 = DefaultEpochDurationSec,
    enablePrecomputation: bool = false,
    precomputeBatchSize: int = 0,
    useInternalEpochTimer: bool = true,
): T =
  ## Parameters:
  ##   totalSlots: R (rate limit budget per epoch)
  ##   epochDurationSec: P (epoch duration in seconds)
  ##   enablePrecomputation: whether to pre-build cover packets in batches
  ##   precomputeBatchSize: packets per batch (0 = auto: R / (1+L) / 10)
  ##   useInternalEpochTimer: false when SpamProtection provides OnEpochChange
  doAssert totalSlots > 0, "totalSlots (R) must be positive"
  doAssert epochDurationSec > 0.0, "epochDurationSec (P) must be positive"

  let intervalSec = ((1 + PathLength).float64 * epochDurationSec) / totalSlots.float64
  let targetCount = totalSlots div (1 + PathLength)
  let batchSize =
    if precomputeBatchSize > 0:
      precomputeBatchSize
    else:
      max(1, targetCount div 10)

  T(
    slotPool: SlotPool.new(totalSlots),
    emissionInterval: intervalSec.toDuration,
    epochDurationSec: epochDurationSec,
    enablePrecomputation: enablePrecomputation,
    precomputeBatchSize: batchSize,
    emissionEpochEvent: newAsyncEvent(),
    precomputeEpochEvent: newAsyncEvent(),
    useInternalEpochTimer: useInternalEpochTimer,
    running: false,
  )

proc emitCoverPacket*(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  if ct.enablePrecomputation and ct.slotPool.queuedCount > 0:
    if not ct.slotPool.claimSlotForCover():
      mix_slots_exhausted.inc(labelValues = ["cover"])
      return
    let prebuilt = ct.slotPool.dequeue()
    if prebuilt.isSome:
      let pkt = prebuilt.get()
      # Check if the prebuilt proof is still valid (e.g., Merkle root not stale)
      if ct.validateProofToken != nil and pkt.proofToken.len > 0 and
          not ct.validateProofToken(pkt.proofToken):
        trace "Prebuilt cover packet has stale proof, falling back to on-demand"
        # Fall through to on-demand building below
      else:
        let sendRes =
          await ct.sendPacket(pkt.firstHopPeerId, pkt.firstHopAddr, pkt.packet)
        if sendRes.isErr:
          debug "Failed to send pre-built cover packet", err = sendRes.error
        else:
          mix_cover_emitted.inc(labelValues = ["prebuilt"])
        return

  if ct.slotPool.claimSlotForCover():
    let buildRes = ct.buildPacket()
    if buildRes.isErr:
      trace "Failed to build cover packet", err = buildRes.error
      return
    let (packet, pid, multiAddr, _) = buildRes.get()
    let sendRes = await ct.sendPacket(pid, multiAddr, packet)
    if sendRes.isErr:
      debug "Failed to send cover packet", err = sendRes.error
    else:
      mix_cover_emitted.inc(labelValues = ["on_demand"])

proc runEmissionLoop(
    ct: ConstantRateCoverTraffic
) {.async: (raises: [CancelledError]).} =
  while ct.running:
    if not ct.slotPool.hasAvailableSlots():
      ct.emissionEpochEvent.clear()
      await ct.emissionEpochEvent.wait()

    await ct.emitCoverPacket()

    # sleepAsync: constant-rate emission requires fixed intervals
    await sleepAsync(ct.emissionInterval)

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
    let targetCount = ct.slotPool.totalSlots div (1 + PathLength)
    let alreadyQueued = ct.slotPool.queuedCount
    var built = 0

    while built + alreadyQueued < targetCount and ct.running:
      if ct.slotPool.epoch != currentEpoch:
        trace "Epoch changed during pre-computation, aborting",
          startedEpoch = currentEpoch, currentEpoch = ct.slotPool.epoch
        break

      let batchEnd = min(built + ct.precomputeBatchSize, targetCount - alreadyQueued)
      var batchFailed = false
      while built < batchEnd:
        let buildRes = ct.buildPacket()
        if buildRes.isErr:
          debug "Pre-computation: failed to build cover packet", err = buildRes.error
          batchFailed = true
          break
        let (packet, pid, multiAddr, proofToken) = buildRes.get()
        ct.slotPool.addPacket(
          CoverPacket(
            packet: packet,
            firstHopPeerId: pid,
            firstHopAddr: multiAddr,
            proofToken: proofToken,
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

    ct.precomputeEpochEvent.clear()
    await ct.precomputeEpochEvent.wait()

proc runEpochTimer(ct: ConstantRateCoverTraffic) {.async: (raises: [CancelledError]).} =
  ## Fallback epoch timer when no SpamProtection provides OnEpochChange.
  var epochCounter: uint64 = 0
  while ct.running:
    # sleepAsync: epoch timer fires at fixed intervals
    let epochDur = ct.epochDurationSec.toDuration
    await sleepAsync(epochDur)
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

  doAssert(ct.buildPacket != nil, "buildPacket callback must be set before start")
  doAssert(ct.sendPacket != nil, "sendPacket callback must be set before start")

  ct.running = true

  ct.emissionLoop = ct.runEmissionLoop()

  if ct.enablePrecomputation:
    ct.precomputeLoop = ct.runPrecomputeLoop()

  if ct.useInternalEpochTimer:
    ct.epochTimerLoop = ct.runEpochTimer()

  trace "Cover traffic started",
    interval = ct.emissionInterval,
    precomputation = ct.enablePrecomputation,
    internalEpochTimer = ct.useInternalEpochTimer

proc cancelIfRunning(fut: Future[void]) {.async: (raises: []).} =
  if not fut.isNil and not fut.finished:
    await fut.cancelAndWait()

method stop*(ct: ConstantRateCoverTraffic) {.async: (raises: []).} =
  if not ct.running:
    return
  ct.running = false
  await cancelIfRunning(ct.emissionLoop)
  await cancelIfRunning(ct.precomputeLoop)
  await cancelIfRunning(ct.epochTimerLoop)
  ct.emissionLoop = nil
  ct.precomputeLoop = nil
  ct.epochTimerLoop = nil
  trace "Cover traffic stopped"

func emissionInterval*(ct: ConstantRateCoverTraffic): Duration =
  ct.emissionInterval

func precomputeBatchSize*(ct: ConstantRateCoverTraffic): int =
  ct.precomputeBatchSize

func isRunning*(ct: ConstantRateCoverTraffic): bool =
  ct.running
