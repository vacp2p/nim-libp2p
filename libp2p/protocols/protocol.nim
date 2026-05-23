# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[tables]
import chronos, results
import ../stream/connection
import ../utils/future

export results

const DefaultMaxIncomingStreams* = 10

type
  LPProtoHandler* = proc(stream: Stream, proto: string): Future[void] {.
    async: (raises: [CancelledError])
  .}

  StreamBudgetState* = ref object
    totalIncoming*: int
    totalOutgoing*: int
    perPeerIncoming*: CountTable[PeerId]
    perPeerOutgoing*: CountTable[PeerId]

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handlerImpl: LPProtoHandler ## invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams: Opt[int]
    # V1 stream budget fields (opt-in; default Opt.none means unlimited)
    maxTotalIncomingStreams*: Opt[int]
    maxOutgoingStreams*: Opt[int] ## outbound per-peer cap
    maxTotalOutgoingStreams*: Opt[int] ## outbound total cap
    # Runtime counters shared across all codecs of this protocol
    streamBudget*: StreamBudgetState

method init*(p: LPProtocol) {.base, gcsafe.} =
  discard

method start*(p: LPProtocol) {.base, async: (raises: [CancelledError], raw: true).} =
  p.started = true
  newFutureCompleted[void]()

method stop*(p: LPProtocol) {.base, async: (raises: [], raw: true).} =
  p.started = false
  newFutureCompleted[void]()

proc maxIncomingStreams*(p: LPProtocol): int =
  p.maxIncomingStreams.get(DefaultMaxIncomingStreams)

proc `maxIncomingStreams=`*(p: LPProtocol, val: int) =
  p.maxIncomingStreams = Opt.some(val)

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

proc toOptInt(v: Opt[int] | int): Opt[int] =
  when v is int:
    Opt.some(v)
  else:
    v

proc new*(
    T: type LPProtocol,
    codecs: seq[string],
    handler: LPProtoHandler,
    maxIncomingStreams: Opt[int] | int = Opt.none(int),
    maxTotalIncomingStreams: Opt[int] | int = Opt.none(int),
    maxOutgoingStreams: Opt[int] | int = Opt.none(int),
    maxTotalOutgoingStreams: Opt[int] | int = Opt.none(int),
): T =
  T(
    codecs: codecs,
    handlerImpl: handler,
    maxIncomingStreams: toOptInt(maxIncomingStreams),
    maxTotalIncomingStreams: toOptInt(maxTotalIncomingStreams),
    maxOutgoingStreams: toOptInt(maxOutgoingStreams),
    maxTotalOutgoingStreams: toOptInt(maxTotalOutgoingStreams),
    streamBudget: StreamBudgetState(
      perPeerIncoming: initCountTable[PeerId](),
      perPeerOutgoing: initCountTable[PeerId](),
    ),
  )

func canAcceptIncoming*(p: LPProtocol, peerId: PeerId): bool =
  ## Returns true if an incoming stream from `peerId` is within all configured
  ## inbound budgets. Returns false when any limit would be exceeded.
  let budget = p.streamBudget
  if budget.isNil:
    return true
  if p.maxIncomingStreams.isSome and
      budget.perPeerIncoming.getOrDefault(peerId) >= p.maxIncomingStreams.get:
    return false
  if p.maxTotalIncomingStreams.isSome and
      budget.totalIncoming >= p.maxTotalIncomingStreams.get:
    return false
  return true

func canOpenOutgoing*(p: LPProtocol, peerId: PeerId): bool =
  ## Returns true if an outgoing stream to `peerId` is within all configured
  ## outbound budgets. Returns false when any limit would be exceeded.
  let budget = p.streamBudget
  if budget.isNil:
    return true
  if p.maxOutgoingStreams.isSome and
      budget.perPeerOutgoing.getOrDefault(peerId) >= p.maxOutgoingStreams.get:
    return false
  if p.maxTotalOutgoingStreams.isSome and
      budget.totalOutgoing >= p.maxTotalOutgoingStreams.get:
    return false
  return true

proc reserveIncoming*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return
  budget.totalIncoming += 1
  budget.perPeerIncoming.inc(peerId)

proc releaseIncoming*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return
  budget.totalIncoming -= 1
  if budget.totalIncoming < 0:
    budget.totalIncoming = 0
  budget.perPeerIncoming.inc(peerId, -1)
  if budget.perPeerIncoming[peerId] == 0:
    budget.perPeerIncoming.del(peerId)

proc reserveOutgoing*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return
  budget.totalOutgoing += 1
  budget.perPeerOutgoing.inc(peerId)

proc releaseOutgoing*(p: LPProtocol, peerId: PeerId) =
  let budget = p.streamBudget
  if budget.isNil:
    return
  budget.totalOutgoing -= 1
  if budget.totalOutgoing < 0:
    budget.totalOutgoing = 0
  budget.perPeerOutgoing.inc(peerId, -1)
  if budget.perPeerOutgoing[peerId] == 0:
    budget.perPeerOutgoing.del(peerId)
