# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[tables]
import chronos, results, metrics
import ../stream/connection
import ../utils/opt

export results

declareCounter(
  libp2p_protocol_stream_cap_rejections_total,
  "protocol stream budget rejections",
  labels = ["protocol", "direction", "scope"],
)

declareGauge(
  libp2p_protocol_streams_open,
  "protocol stream instances currently open",
  labels = ["protocol", "direction"],
)

export libp2p_protocol_stream_cap_rejections_total, libp2p_protocol_streams_open

const
  scopeTotal = "total"
  scopePeerPeer = "per_peer"

type
  LPProtoHandler* = proc(stream: Stream, proto: string): Future[void] {.
    async: (raises: [CancelledError])
  .}

  StreamBudgetState = ref object
    totalIncoming: int
    totalOutgoing: int
    perPeerIncoming: CountTable[PeerId]
    perPeerOutgoing: CountTable[PeerId]

  LPProtocol* = ref object of RootObj
    started*: bool
    codecs*: seq[string]
    handlerImpl: LPProtoHandler ## invoked by the protocol negotiator
    maxIncomingStreamsTotal: Opt[int]
    maxIncomingStreamsPerPeer: Opt[int]
    maxOutgoingStreamsTotal: Opt[int]
    maxOutgoingStreamsPerPeer: Opt[int]
    streamBudget: StreamBudgetState
      ## Runtime counters shared across all codecs of this protocol

method init*(p: LPProtocol) {.base, gcsafe.} =
  discard

method start*(p: LPProtocol) {.base, async: (raises: [CancelledError]).} =
  p.started = true

method stop*(p: LPProtocol) {.base, async: (raises: []).} =
  p.started = false

func codec*(p: LPProtocol): string =
  doAssert(p.codecs.len > 0, "Codecs sequence was empty!")
  p.codecs[0]

func `codec=`*(p: LPProtocol, codec: string) =
  # always insert as first codec
  # if we use this abstraction
  p.codecs.insert(codec, 0)

template `handler`*(p: LPProtocol): LPProtoHandler =
  p.handlerImpl

template `handler`*(p: LPProtocol, stream: Stream, proto: string): Future[void] =
  p.handlerImpl(stream, proto)

func `handler=`*(p: LPProtocol, handler: LPProtoHandler) =
  p.handlerImpl = handler

proc new*(
    T: type LPProtocol,
    codecs: seq[string],
    handler: LPProtoHandler,
    maxIncomingStreamsTotal: Opt[int] | int = Opt.none(int),
    maxIncomingStreamsPerPeer: Opt[int] | int = Opt.none(int),
    maxOutgoingStreamsTotal: Opt[int] | int = Opt.none(int),
    maxOutgoingStreamsPerPeer: Opt[int] | int = Opt.none(int),
): T =
  T(
    codecs: codecs,
    handlerImpl: handler,
    maxIncomingStreamsTotal: toOpt(maxIncomingStreamsTotal),
    maxIncomingStreamsPerPeer: toOpt(maxIncomingStreamsPerPeer),
    maxOutgoingStreamsTotal: toOpt(maxOutgoingStreamsTotal),
    maxOutgoingStreamsPerPeer: toOpt(maxOutgoingStreamsPerPeer),
    streamBudget: StreamBudgetState(
      perPeerIncoming: initCountTable[PeerId](),
      perPeerOutgoing: initCountTable[PeerId](),
    ),
  )

func budgetReason(p: LPProtocol, peerId: PeerId, dir: Direction): (bool, string) =
  ## Returns (canAccept, scope) indicating whether a stream can be accepted
  ## and which scope would reject it.
  let budget = p.streamBudget
  if budget.isNil:
    return (true, "")

  if dir == Direction.In:
    if p.maxIncomingStreamsPerPeer.isSome and
        budget.perPeerIncoming.getOrDefault(peerId) >= p.maxIncomingStreamsPerPeer.get:
      return (false, scopePeerPeer)
    if p.maxIncomingStreamsTotal.isSome and
        budget.totalIncoming >= p.maxIncomingStreamsTotal.get:
      return (false, scopeTotal)
  else:
    if p.maxOutgoingStreamsPerPeer.isSome and
        budget.perPeerOutgoing.getOrDefault(peerId) >= p.maxOutgoingStreamsPerPeer.get:
      return (false, scopePeerPeer)
    if p.maxOutgoingStreamsTotal.isSome and
        budget.totalOutgoing >= p.maxOutgoingStreamsTotal.get:
      return (false, scopeTotal)

  return (true, "")

func canAcceptIncoming*(p: LPProtocol, peerId: PeerId): bool =
  ## Returns true if an incoming stream from `peerId` is within all configured
  ## inbound budgets. Returns false when any limit would be exceeded.
  let (canAccept, _) = p.budgetReason(peerId, Direction.In)
  canAccept

proc reserveIncoming*(p: LPProtocol, peerId: PeerId): bool =
  let budget = p.streamBudget
  if budget.isNil:
    return true

  let (canAccept, scope) = p.budgetReason(peerId, Direction.In)
  if not canAccept:
    libp2p_protocol_stream_cap_rejections_total.inc(
      labelValues = [p.codec, "in", scope]
    )
    return false

  budget.totalIncoming.inc
  budget.perPeerIncoming.inc(peerId)
  libp2p_protocol_streams_open.inc(labelValues = [p.codec, "in"])
  return true

proc releaseIncoming*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return

  let pb = budget.perPeerIncoming[peerId]
  if pb == 0:
    return # there was no reserve for this peer
  elif pb == 1:
    budget.perPeerIncoming.del(peerId)
  else:
    budget.perPeerIncoming.inc(peerId, -1)

  budget.totalIncoming.dec
  libp2p_protocol_streams_open.dec(labelValues = [p.codec, "in"])

func canOpenOutgoing*(p: LPProtocol, peerId: PeerId): bool =
  ## Returns true if an outgoing stream to `peerId` is within all configured
  ## outbound budgets. Returns false when any limit would be exceeded.
  let (canAccept, _) = p.budgetReason(peerId, Direction.Out)
  canAccept

proc reserveOutgoing*(p: LPProtocol, peerId: PeerId): bool =
  let budget = p.streamBudget
  if budget.isNil:
    return true

  let (canAccept, scope) = p.budgetReason(peerId, Direction.Out)
  if not canAccept:
    libp2p_protocol_stream_cap_rejections_total.inc(
      labelValues = [p.codec, "out", scope]
    )
    return false

  budget.totalOutgoing.inc
  budget.perPeerOutgoing.inc(peerId)
  libp2p_protocol_streams_open.inc(labelValues = [p.codec, "out"])
  return true

proc releaseOutgoing*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return

  let pb = budget.perPeerOutgoing[peerId]
  if pb == 0:
    return # there was no reserve for this peer
  elif pb == 1:
    budget.perPeerOutgoing.del(peerId)
  else:
    budget.perPeerOutgoing.inc(peerId, -1)

  budget.totalOutgoing.dec
  libp2p_protocol_streams_open.dec(labelValues = [p.codec, "out"])
