# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Shared DHT peer row store. Routing tables are indexes over this registry:
## they hold ``Key`` references only; liveness/usefulness state lives here once.
## Usefulness grace is membership-local via ``Membership.addedAt``.

import std/[tables, sets]
import chronos, results
import ./types
import ../../peerid

{.push raises: [].}

proc new*(T: typedesc[PeerRegistry]): PeerRegistry =
  PeerRegistry(
    peers: initTable[Key, PeerRecord](),
    tablesByPeer: initTable[Key, Table[Key, Membership]](),
  )

func contains*(registry: PeerRegistry, nodeId: Key): bool =
  nodeId in registry.peers

func get*(registry: PeerRegistry, nodeId: Key): Opt[PeerRecord] =
  registry.peers.withValue(nodeId, record):
    return Opt.some(record[])
  Opt.none(PeerRecord)

func len*(registry: PeerRegistry): int =
  registry.peers.len

func membership*(registry: PeerRegistry, nodeId: Key, tableId: Key): Opt[Membership] =
  registry.tablesByPeer.withValue(nodeId, tables):
    tables[].withValue(tableId, m):
      return Opt.some(m[])
  Opt.none(Membership)

func lastActivity*(record: PeerRecord, membership: Membership): Moment =
  ## Most recent useful answer, else when this table first indexed the peer.
  record.lastUsefulAt.get(membership.addedAt)

func isReplaceable*(
    record: PeerRecord, membership: Membership, gracePeriod: Duration, now: Moment
): bool =
  ## Replaceable once past ``gracePeriod`` without proving useful. Grace starts
  ## at membership ``addedAt`` (per table), not at first global sighting.
  now - record.lastActivity(membership) > gracePeriod

proc upsert*(registry: PeerRegistry, nodeId: Key, now = Moment.now()): PeerRecord =
  ## Insert a new peer row, or refresh ``lastSeen`` if one already exists.
  ## Does not add table membership.
  registry.peers.withValue(nodeId, existing):
    existing[].lastSeen = now
    return existing[]
  let record = PeerRecord(nodeId: nodeId, lastSeen: now, lastUsefulAt: Opt.none(Moment))
  registry.peers[nodeId] = record
  record

proc markUseful*(registry: PeerRegistry, nodeId: Key, now = Moment.now()) =
  ## Peer answered a query: refresh usefulness so it survives eviction in every
  ## table that indexes it.
  registry.peers.withValue(nodeId, record):
    record[].lastUsefulAt = Opt.some(now)
    record[].lastSeen = now

proc markUseful*(registry: PeerRegistry, peerId: PeerId, now = Moment.now()) =
  registry.markUseful(peerId.toKey(), now)

proc addMembership*(
    registry: PeerRegistry, nodeId: Key, tableId: Key, now = Moment.now()
) =
  ## Record that ``tableId`` indexes ``nodeId``. Fresh membership starts grace.
  ## No-op when the peer is already a member of this table.
  if nodeId notin registry.tablesByPeer:
    registry.tablesByPeer[nodeId] = initTable[Key, Membership]()
  registry.tablesByPeer.withValue(nodeId, tables):
    if tableId in tables[]:
      return
    tables[][tableId] = Membership(addedAt: now)

proc removeMembership*(registry: PeerRegistry, nodeId: Key, tableId: Key) =
  ## Drop one table's reference. When no tables remain, delete the peer row.
  registry.tablesByPeer.withValue(nodeId, tables):
    tables[].del(tableId)
    if tables[].len > 0:
      return
    registry.tablesByPeer.del(nodeId)
    registry.peers.del(nodeId)
    return
  # Membership missing but a row may still exist (failed insert path).
  if nodeId in registry.peers and nodeId notin registry.tablesByPeer:
    registry.peers.del(nodeId)

proc dropTable*(registry: PeerRegistry, tableId: Key) =
  ## Remove every membership for ``tableId``. Deletes peer rows that lose their
  ## last table reference. Call when a routing table is destroyed.
  var emptyPeers: seq[Key]
  for nodeId, tables in registry.tablesByPeer.mpairs:
    tables.del(tableId)
    if tables.len == 0:
      emptyPeers.add(nodeId)
  for nodeId in emptyPeers:
    registry.tablesByPeer.del(nodeId)
    registry.peers.del(nodeId)

proc dropPeer*(registry: PeerRegistry, nodeId: Key) =
  ## Remove the peer row and all membership tracking. Callers must also drop
  ## the key from every routing-table bucket that still holds it.
  registry.peers.del(nodeId)
  registry.tablesByPeer.del(nodeId)

func tableIds*(registry: PeerRegistry, nodeId: Key): HashSet[Key] =
  result = initHashSet[Key]()
  registry.tablesByPeer.withValue(nodeId, tables):
    for tableId in tables[].keys:
      result.incl(tableId)

func isReplaceable*(
    registry: PeerRegistry,
    nodeId: Key,
    tableId: Key,
    gracePeriod: Duration,
    now: Moment,
): bool =
  ## True when the peer is past grace for ``tableId``. Missing row or membership
  ## (orphan index entry) is treated as replaceable so eviction can clean it up.
  let membership = registry.membership(nodeId, tableId).valueOr:
    return true
  let record = registry.get(nodeId).valueOr:
    return true
  record.isReplaceable(membership, gracePeriod, now)

func isReplaceable*(
    registry: PeerRegistry,
    peerId: PeerId,
    tableId: Key,
    gracePeriod: Duration,
    now: Moment,
): bool =
  registry.isReplaceable(peerId.toKey(), tableId, gracePeriod, now)
