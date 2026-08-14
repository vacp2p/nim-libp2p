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

proc probeBackedOff*(kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]): bool =
  ## An unprobed address set earns a probe, so a bogus address cannot hold back the real one.
  let failure = kad.probeFailures.getOrDefault(peerId)
  failure.count > 0 and Moment.now() < failure.until and
    failure.addrs == addrs.probeAddrsDigest()

proc probePruneFailures(kad: KadDHT, now: Moment) =
  ## Make room for one entry: elapsed backoffs first, then soonest to elapse.
  let cap = kad.config.limits.maxProbeFailures
  if kad.probeFailures.len < cap:
    return

  for peerId in kad.probeFailures.keys().toSeq():
    if now >= kad.probeFailures.getOrDefault(peerId).until:
      kad.probeFailures.del(peerId)

  let excess = kad.probeFailures.len - cap + 1
  if excess <= 0:
    return

  var byExpiry = kad.probeFailures.pairs().toSeq()
  byExpiry.sort(
    proc(a, b: (PeerId, ProbeFailure)): int =
      cmp(a[1].until, b[1].until)
  )
  for i in 0 ..< excess:
    kad.probeFailures.del(byExpiry[i][0])

proc probeRecordFailure*(kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]) =
  let now = Moment.now()
  kad.probePruneFailures(now)
  let count = kad.probeFailures.getOrDefault(peerId).count + 1
  kad.probeFailures[peerId] = ProbeFailure(
    count: count,
    until: now + probeBackoff(count, kad.config.timeout, kad.config.probeBackoffMax),
    addrs: addrs.probeAddrsDigest(),
  )

proc probeClearFailures*(kad: KadDHT, peerId: PeerId) =
  kad.probeFailures.del(peerId)
