# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import multiaddress, multicodec, peerid

type
  DialCandidate* = object
    ## One address a dial can attempt, with dnsaddr and DNS already resolved.
    address*: MultiAddress
    hostname*: string ## Host the address was reached under, for TLS and the Host header.
    peerId*: Opt[PeerId] ## Pinned by a dnsaddr record, otherwise the dialed peer's.
    fromName*: bool ## A lookup chose this address, so the address policy sees it again.

  DialRank* {.pure.} = enum
    ## Ranked from the first candidate dialed to the last.
    DirectQuic
    Direct
    RelayQuic
    Relay

const circuitCodec = multiCodec("p2p-circuit")

func key*(candidate: DialCandidate): string =
  ## Two candidates with the same key stand for the same dial.
  $candidate.address & "|" & candidate.hostname & "|" & $candidate.peerId

func dialRank*(candidate: DialCandidate): DialRank =
  ## A circuit address starts with the relay's own transport, so a prefix match ranks both.
  let
    relayed = candidate.address.contains(circuitCodec).get(false)
    quic =
      QUIC_V1.matchPartial(candidate.address) or QUIC.matchPartial(candidate.address)
  if relayed:
    if quic: DialRank.RelayQuic else: DialRank.Relay
  else:
    if quic: DialRank.DirectQuic else: DialRank.Direct
