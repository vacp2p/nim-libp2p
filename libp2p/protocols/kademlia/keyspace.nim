# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Keyspace regions: keys whose hashes share a leading bit prefix. Once a region
## holds ``replication`` peers, every key in it has all of its closest peers
## inside the region, so one walk toward any member key serves them all.

import std/[algorithm, sequtils, tables]
import results
import ../../peerid
import ./[types, routing_table]

type RegionPrefix* = seq[byte]
  ## Leading bits of a hashed key, trailing bits of the last byte cleared.

func regionPrefix*(key: Key, bits: int, hasher: Opt[XorDHasher]): RegionPrefix =
  let hashed = key.hashFor(hasher)
  let width = clamp(bits, 0, hashed.len * 8)
  var prefix = hashed[0 ..< width div 8]
  let partial = width mod 8
  if partial > 0:
    prefix.add(hashed[width div 8] and (0xFF'u8 shl (8 - partial)))
  prefix

func keyspaceRegions*(
    keys: seq[Key], bits: int, hasher: Opt[XorDHasher]
): seq[seq[Key]] =
  ## Partition `keys` by prefix, each region in the order its first key appears.
  ## `bits == 0` yields a single region.
  var
    order: seq[RegionPrefix]
    regions: Table[RegionPrefix, seq[Key]]
  for key in keys:
    let prefix = key.regionPrefix(bits, hasher)
    if prefix notin regions:
      order.add(prefix)
    regions.mgetOrPut(prefix, @[]).add(key)
  order.mapIt(regions.getOrDefault(it))

func regionBits*(rtable: RoutingTable): Opt[int] =
  ## Prefix length that splits the keyspace into regions of at least
  ## ``replication`` peers each. Bucket ``d`` covers a ``2^-(d+1)`` slice, so a
  ## deepest full bucket ``d`` sizes the network at ``replication * 2^(d+1)``
  ## peers and ``d + 1`` bits cut it into regions of ``replication`` peers.
  ## ``Opt.none`` while no bucket is full: the table has no size estimate yet.
  var deepestFull = -1
  for i in 0 ..< rtable.buckets.len:
    if rtable.buckets[i].peers.len >= rtable.config.replication:
      deepestFull = i

  if deepestFull < 0:
    return Opt.none(int)
  Opt.some(min(deepestFull + 1, MaxRegionBits))

func closestFirst*(peers: seq[PeerId], key: Key, hasher: Opt[XorDHasher]): seq[PeerId] =
  ## `peers` ordered by XOR distance to `key`, closest first.
  peers
    .mapIt((it, xorDistance(it, key, hasher)))
    .sorted(
      proc(a, b: (PeerId, XorDistance)): int =
        cmp(a[1], b[1])
    )
    .mapIt(it[0])
