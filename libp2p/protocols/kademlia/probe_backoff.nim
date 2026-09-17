# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Hold back a peer whose admission probe failed.
## The probe slot frees on ``config.timeout`` while the dial under it runs to the
## dialer's own, longer timeout, so without this cache the next reply naming the
## peer re-probes it, queues on the dial lock, and burns a slot for nothing.

{.push raises: [].}

import std/[algorithm, hashes, sequtils, tables]
import chronos
import ../../[multiaddress, peerid]
import ./types

func probeBackoff*(count: int, base, cap: Duration): Duration =
  ## Doubles per consecutive failure, and never passes ``cap``.
  var backoff = base
  for _ in 1 ..< count:
    if backoff >= cap:
      break
    backoff = backoff * 2
  min(backoff, cap)

func probeAddrsDigest(addrs: seq[MultiAddress]): Hash =
  ## Summed in wrapping arithmetic, so the digest holds for any address order.
  var digest: uint64 = 0
  for ma in addrs:
    digest = digest + cast[uint64](hash(ma))
  cast[Hash](digest)

proc backedOff*(
    failures: Table[PeerId, ProbeFailure], peerId: PeerId, addrs: seq[MultiAddress]
): bool =
  ## An unprobed address set earns a probe, so a bogus address cannot hold back the real one.
  let failure = failures.getOrDefault(peerId)
  failure.count > 0 and Moment.now() < failure.until and
    failure.addrs == addrs.probeAddrsDigest()

proc pruneFailures(failures: var Table[PeerId, ProbeFailure], now: Moment, cap: int) =
  ## Make room for one entry: elapsed backoffs first, then soonest to elapse.
  if failures.len < cap:
    return

  for peerId in failures.keys().toSeq():
    if now >= failures.getOrDefault(peerId).until:
      failures.del(peerId)

  let excess = failures.len - cap + 1
  if excess <= 0:
    return

  var byExpiry = failures.pairs().toSeq()
  byExpiry.sort(
    proc(a, b: (PeerId, ProbeFailure)): int =
      cmp(a[1].until, b[1].until)
  )
  for i in 0 ..< excess:
    failures.del(byExpiry[i][0])

proc recordFailure*(
    failures: var Table[PeerId, ProbeFailure],
    peerId: PeerId,
    addrs: seq[MultiAddress],
    base, cap: Duration,
    maxEntries: int,
): int {.discardable.} =
  ## Returns the consecutive failure count the peer has now reached.
  let now = Moment.now()
  let count = failures.getOrDefault(peerId).count + 1
  ## A repeat offender overwrites its own entry, so a prune would drop the count it just read.
  if count == 1:
    failures.pruneFailures(now, maxEntries)
  failures[peerId] = ProbeFailure(
    count: count,
    until: now + probeBackoff(count, base, cap),
    addrs: addrs.probeAddrsDigest(),
  )
  count

proc probeBackedOff*(kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]): bool =
  kad.probeFailures.backedOff(peerId, addrs)

proc probeRecordFailure*(kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]) =
  kad.probeFailures.recordFailure(
    peerId, addrs, kad.config.timeout, kad.config.probeBackoffMax,
    kad.config.limits.maxProbeFailures,
  )

proc probeClearFailures*(kad: KadDHT, peerId: PeerId) =
  kad.probeFailures.del(peerId)
