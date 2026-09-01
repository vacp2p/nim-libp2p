# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/tables

import pkg/[chronos, chronicles, metrics]

import multiaddress, peerid, utils/opt

logScope:
  topics = "libp2p dialbackoff"

declareCounter libp2p_dial_backoffs,
  "failures that started or raised a backoff", ["scope"]
declareCounter libp2p_dial_backoff_skips, "dials skipped while on backoff", ["scope"]

const MaxBackoffEntries* = 1024
  ## Cap per table, so a peer that names a fresh address per dial stays bounded.

type
  DialBackoffConfig* = object
    tolerance*: int ## consecutive failures dialed before the first backoff
    base*: Duration ## wait after the first failure over the tolerance
    factor*: int ## multiplier that each further failure applies
    maxDelay*: Duration
      ## ceiling on the wait, and the idle time an entry keeps its count

  BackoffEntry = object
    failures: int
    until: Moment

  DialBackoff* = ref object
    config: DialBackoffConfig
    peers: Table[PeerId, BackoffEntry]
    addrs: Table[MultiAddress, BackoffEntry]

const DefaultDialBackoff* =
  DialBackoffConfig(tolerance: 2, base: 5.seconds, factor: 2, maxDelay: 5.minutes)

func delay(config: DialBackoffConfig, failures: int): Duration =
  ## The wait after `failures` consecutive failures, zero under the tolerance.

  if failures <= config.tolerance:
    return ZeroDuration

  var delay = config.base
  for _ in 1 ..< failures - config.tolerance:
    if delay > config.maxDelay div config.factor:
      return config.maxDelay
    delay = delay * config.factor

  if delay > config.maxDelay: config.maxDelay else: delay

func decayed(config: DialBackoffConfig, entry: BackoffEntry, now: Moment): bool =
  ## True once the entry spent a full `maxDelay` blocking nothing.
  entry.until + config.maxDelay <= now

proc prune[K](
    entries: var Table[K, BackoffEntry], config: DialBackoffConfig, now: Moment
) =
  var stale: seq[K]
  for key, entry in entries:
    if config.decayed(entry, now):
      stale.add(key)

  for key in stale:
    entries.del(key)

proc evictSoonest[K](entries: var Table[K, BackoffEntry]) =
  ## Drop the entry whose wait ends first, so a full table keeps taking failures.

  var
    soonest: K
    ends: Moment
    empty = true

  for key, entry in entries:
    if empty or entry.until < ends:
      soonest = key
      ends = entry.until
      empty = false

  if not empty:
    entries.del(soonest)

proc blockedIn[K](
    entries: Table[K, BackoffEntry], key: K, scope: string, now: Moment
): bool =
  let entry = entries.getOrDefault(key, BackoffEntry(until: now))
  if entry.until <= now:
    return false

  libp2p_dial_backoff_skips.inc(labelValues = [scope])
  debug "Skipping the dial, it is on backoff",
    scope, key, backoffMs = (entry.until - now).milliseconds
  true

proc countFailure[K](
    self: DialBackoff,
    entries: var Table[K, BackoffEntry],
    key: K,
    scope: string,
    now: Moment,
) =
  if entries.len >= MaxBackoffEntries and key notin entries:
    entries.prune(self.config, now)
    if entries.len >= MaxBackoffEntries:
      entries.evictSoonest()

  var entry = entries.getOrDefault(key, BackoffEntry(until: now))
  if self.config.decayed(entry, now):
    entry = BackoffEntry(until: now)

  entry.failures.inc()
  entry.until = now + self.config.delay(entry.failures)
  entries[key] = entry

  if entry.until <= now:
    return

  libp2p_dial_backoffs.inc(labelValues = [scope])
  debug "Backing the dial off",
    scope, key, failures = entry.failures, backoffMs = (entry.until - now).milliseconds

proc blocked*(self: DialBackoff, peerId: PeerId, now = Moment.now()): bool =
  if self.isNil():
    return false
  self.peers.blockedIn(peerId, "peer", now)

proc blocked*(self: DialBackoff, address: MultiAddress, now = Moment.now()): bool =
  if self.isNil():
    return false
  self.addrs.blockedIn(address, "address", now)

proc blocked*(self: DialBackoff, peerId: Opt[PeerId], now = Moment.now()): bool =
  peerId.withValue(pid):
    return self.blocked(pid, now)
  false

proc recordFailure*(self: DialBackoff, peerId: PeerId, now = Moment.now()) =
  if self.isNil():
    return
  self.countFailure(self.peers, peerId, "peer", now)

proc recordFailure*(self: DialBackoff, address: MultiAddress, now = Moment.now()) =
  if self.isNil():
    return
  self.countFailure(self.addrs, address, "address", now)

proc recordFailure*(self: DialBackoff, peerId: Opt[PeerId], now = Moment.now()) =
  peerId.withValue(pid):
    self.recordFailure(pid, now)

proc recordSuccess*(self: DialBackoff, peerId: PeerId) =
  if self.isNil():
    return
  self.peers.del(peerId)

proc recordSuccess*(self: DialBackoff, address: MultiAddress) =
  if self.isNil():
    return
  self.addrs.del(address)

proc recordSuccess*(self: DialBackoff, peerId: Opt[PeerId]) =
  peerId.withValue(pid):
    self.recordSuccess(pid)

proc new*(T: type DialBackoff, config = DefaultDialBackoff): T =
  T(
    config: DialBackoffConfig(
      tolerance: max(config.tolerance, 0),
      base: config.base,
      factor: max(config.factor, 1),
      maxDelay: config.maxDelay,
    )
  )
