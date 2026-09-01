# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results
import ../../libp2p/[dialbackoff, multiaddress, peerid]
import ../tools/[unittest, crypto]

proc memoryAddr(i: int): MultiAddress =
  MultiAddress.init("/memorytransport/addr-" & $i).tryGet()

suite "Dial backoff":
  let config =
    DialBackoffConfig(tolerance: 2, base: 1.seconds, factor: 2, maxDelay: 8.seconds)

  test "A failure under the tolerance blocks nothing":
    let
      backoff = DialBackoff.new(config)
      peerId = PeerId.random(rng()).tryGet()
      start = Moment.now()

    backoff.recordFailure(peerId, start)
    backoff.recordFailure(peerId, start)

    check not backoff.blocked(peerId, start)

  test "The wait doubles with each further failure":
    let
      backoff = DialBackoff.new(config)
      peerId = PeerId.random(rng()).tryGet()
      start = Moment.now()

    for _ in 0 ..< 3:
      backoff.recordFailure(peerId, start)
    check:
      backoff.blocked(peerId, start + 900.milliseconds)
      not backoff.blocked(peerId, start + 1100.milliseconds)

    backoff.recordFailure(peerId, start)
    check:
      backoff.blocked(peerId, start + 1900.milliseconds)
      not backoff.blocked(peerId, start + 2100.milliseconds)

  test "The wait stops at the ceiling":
    let
      backoff = DialBackoff.new(config)
      peerId = PeerId.random(rng()).tryGet()
      start = Moment.now()

    for _ in 0 ..< 20:
      backoff.recordFailure(peerId, start)

    check:
      backoff.blocked(peerId, start + 7.seconds)
      not backoff.blocked(peerId, start + 9.seconds)

  test "A successful dial clears the backoff":
    let
      backoff = DialBackoff.new(config)
      peerId = PeerId.random(rng()).tryGet()
      start = Moment.now()

    for _ in 0 ..< 4:
      backoff.recordFailure(peerId, start)
    check backoff.blocked(peerId, start)

    backoff.recordSuccess(peerId)
    check not backoff.blocked(peerId, start)

    backoff.recordFailure(peerId, start)
    backoff.recordFailure(peerId, start)
    check not backoff.blocked(peerId, start)

  test "The peer scope and the address scope count apart":
    let
      backoff = DialBackoff.new(
        DialBackoffConfig(tolerance: 0, base: 1.seconds, factor: 2, maxDelay: 8.seconds)
      )
      peerId = PeerId.random(rng()).tryGet()
      address = memoryAddr(0)
      start = Moment.now()

    backoff.recordFailure(address, start)
    check:
      backoff.blocked(address, start)
      not backoff.blocked(peerId, start)

    backoff.recordSuccess(address)
    backoff.recordFailure(peerId, start)
    check:
      not backoff.blocked(address, start)
      backoff.blocked(peerId, start)

  test "A dial without a peer id is never blocked":
    let
      backoff = DialBackoff.new(
        DialBackoffConfig(tolerance: 0, base: 1.seconds, factor: 2, maxDelay: 8.seconds)
      )
      start = Moment.now()

    backoff.recordFailure(Opt.none(PeerId), start)
    check not backoff.blocked(Opt.none(PeerId), start)

  test "A nil backoff blocks nothing":
    let
      backoff: DialBackoff = nil
      peerId = PeerId.random(rng()).tryGet()
      start = Moment.now()

    backoff.recordFailure(peerId, start)
    backoff.recordFailure(memoryAddr(0), start)
    backoff.recordSuccess(peerId)
    check:
      not backoff.blocked(peerId, start)
      not backoff.blocked(memoryAddr(0), start)

  test "An idle entry decays, and the count starts over":
    let
      backoff = DialBackoff.new(config)
      address = memoryAddr(0)
      start = Moment.now()

    for _ in 0 ..< 3:
      backoff.recordFailure(address, start)
    check backoff.blocked(address, start)

    let later = start + 1.seconds + 8.seconds + 1.seconds
    backoff.recordFailure(address, later)
    backoff.recordFailure(address, later)
    check not backoff.blocked(address, later)

  test "A full table drops the entry whose wait ends first":
    let
      backoff = DialBackoff.new(
        DialBackoffConfig(tolerance: 0, base: 1.minutes, factor: 1, maxDelay: 1.minutes)
      )
      start = Moment.now()
      extra = memoryAddr(MaxBackoffEntries)

    for i in 0 ..< MaxBackoffEntries:
      backoff.recordFailure(memoryAddr(i), start + i.milliseconds)

    let now = start + 2.seconds
    backoff.recordFailure(extra, now)
    check:
      backoff.blocked(extra, now)
      not backoff.blocked(memoryAddr(0), now)
      backoff.blocked(memoryAddr(1), now)
