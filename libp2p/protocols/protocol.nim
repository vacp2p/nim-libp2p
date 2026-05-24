# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[tables]
import chronos, results
import ../stream/connection

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
    maxIncomingStreamsTotal*: Opt[int]
    maxIncomingStreamsPerPeer: Opt[int]
    maxOutgoingStreamsTotal*: Opt[int]
    maxOutgoingStreamsPerPeer*: Opt[int]
    # Runtime counters shared across all codecs of this protocol
    streamBudget*: StreamBudgetState

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

proc toOptInt(v: Opt[int] | int): Opt[int] =
  when v is int:
    Opt.some(v)
  else:
    v

proc new*(
    T: type LPProtocol,
    codecs: seq[string],
    handler: LPProtoHandler,
    maxIncomingStreamsTotal: Opt[int] | int = Opt.none(int),
    maxIncomingStreamsPerPeer: Opt[int] | int = 10,
    maxOutgoingStreamsTotal: Opt[int] | int = Opt.none(int),
    maxOutgoingStreamsPerPeer: Opt[int] | int = 10,
): T =
  T(
    codecs: codecs,
    handlerImpl: handler,
    maxIncomingStreamsTotal: toOptInt(maxIncomingStreamsTotal),
    maxIncomingStreamsPerPeer: toOptInt(maxIncomingStreamsPerPeer),
    maxOutgoingStreamsTotal: toOptInt(maxOutgoingStreamsTotal),
    maxOutgoingStreamsPerPeer: toOptInt(maxOutgoingStreamsPerPeer),
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
  if p.maxIncomingStreamsPerPeer.isSome and
      budget.perPeerIncoming.getOrDefault(peerId) >= p.maxIncomingStreamsPerPeer.get:
    return false
  if p.maxIncomingStreamsTotal.isSome and
      budget.totalIncoming >= p.maxIncomingStreamsTotal.get:
    return false
  return true

func canOpenOutgoing*(p: LPProtocol, peerId: PeerId): bool =
  ## Returns true if an outgoing stream to `peerId` is within all configured
  ## outbound budgets. Returns false when any limit would be exceeded.
  let budget = p.streamBudget
  if budget.isNil:
    return true
  if p.maxOutgoingStreamsPerPeer.isSome and
      budget.perPeerOutgoing.getOrDefault(peerId) >= p.maxOutgoingStreamsPerPeer.get:
    return false
  if p.maxOutgoingStreamsTotal.isSome and
      budget.totalOutgoing >= p.maxOutgoingStreamsTotal.get:
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
