# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import pkg/chronos

import multiaddress, multicodec, peerid, wire

type
  DialCandidate* = object
    ## One address a dial can attempt, with dnsaddr and DNS already resolved.
    address*: MultiAddress
    hostname*: string ## Host the address was reached under, for TLS and the Host header.
    peerId*: Opt[PeerId] ## Pinned by a dnsaddr record, otherwise the dialed peer's.
    fromName*: bool ## A lookup chose this address, so the address policy sees it again.

  DialGroup* {.pure.} = enum
    ## Ranked from the first group dialed to the last.
    Quic ## a direct QUIC address
    Direct ## a direct address over any other transport
    Relay ## an address behind a circuit relay

  DialScope {.pure.} = enum
    Public ## a globally routable address
    Private ## loopback, link-local, a private network, or no IP at all

  DialRankingConfig* = object
    quicHeadStart*: Duration
      ## how long public QUIC dials alone before the other public direct transports join
    privateQuicHeadStart*: Duration
      ## the same head start among private addresses, where a handshake takes milliseconds
    relayDelay*: Duration ## how long direct dials run alone before the relays join them
    maxParallelDials*: int ## attempts one peer dial holds open at once

  DialPlan* = object
    ## What one peer dial learned so far, which sets how long each candidate waits.
    config: DialRankingConfig
    quicScopes: set[DialScope]
    direct: bool

const DefaultDialRanking* = DialRankingConfig(
  quicHeadStart: 250.milliseconds,
  privateQuicHeadStart: 30.milliseconds,
  relayDelay: 500.milliseconds,
  maxParallelDials: 8,
)

const circuitCodec = multiCodec("p2p-circuit")

func key*(candidate: DialCandidate): string =
  ## Two candidates with the same key stand for the same dial.
  $candidate.address & "|" & candidate.hostname & "|" & $candidate.peerId

proc dialGroup*(candidate: DialCandidate): DialGroup =
  if candidate.address.contains(circuitCodec).get(false):
    DialGroup.Relay
  elif QUIC_V1.match(candidate.address) or QUIC.match(candidate.address):
    DialGroup.Quic
  else:
    DialGroup.Direct

proc dialScope(candidate: DialCandidate): DialScope =
  if candidate.address.isPublicMA(): DialScope.Public else: DialScope.Private

func init*(T: type DialPlan, config: DialRankingConfig): T =
  T(config: config)

proc add*(plan: var DialPlan, candidate: DialCandidate) =
  ## Learn a candidate of the dial, whether it is dialed yet or not.
  case candidate.dialGroup()
  of DialGroup.Quic:
    plan.quicScopes.incl(candidate.dialScope())
    plan.direct = true
  of DialGroup.Direct:
    plan.direct = true
  of DialGroup.Relay:
    discard

proc dialDelay*(plan: DialPlan, candidate: DialCandidate): Duration =
  ## How long after the dial starts the candidate waits, given what the dial learned.
  case candidate.dialGroup()
  of DialGroup.Quic:
    ZeroDuration
  of DialGroup.Direct:
    let scope = candidate.dialScope()
    if scope notin plan.quicScopes:
      ZeroDuration
    elif scope == DialScope.Public:
      plan.config.quicHeadStart
    else:
      plan.config.privateQuicHeadStart
  of DialGroup.Relay:
    if plan.direct: plan.config.relayDelay else: ZeroDuration
