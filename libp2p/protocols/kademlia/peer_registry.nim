# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Shared DHT peer row store. Routing tables are indexes over this registry:
## they hold ``Key`` references only; liveness/usefulness state lives here once.

import std/[tables, sets]
import chronos, results
import ./types
import ../../peerid

{.push raises: [].}

proc new*(T: typedesc[PeerRegistry]): PeerRegistry =
  PeerRegistry(
    peers: initTable[Key, PeerRecord](), tablesByPeer: initTable[Key, HashSet[Key]]()
  )

func contains*(registry: PeerRegistry, nodeId: Key): bool =
  nodeId in registry.peers

func get*(registry: PeerRegistry, nodeId: Key): Opt[PeerRecord] =
  registry.peers.withValue(nodeId, record):
    return Opt.some(record[])
  Opt.none(PeerRecord)

func len*(registry: PeerRegistry): int =
  registry.peers.len

func lastActivity*(record: PeerRecord): Moment =
  ## Most recent time the peer answered a DHT query, or when it was first recorded.
  record.lastUsefulAt.get(record.addedAt)

func isReplaceable*(record: PeerRecord, gracePeriod: Duration, now: Moment): bool =
  ## Replaceable once past ``gracePeriod`` without proving useful. Grace is global
  ## (from first registry sighting), not per routing-table membership.
  now - record.lastActivity() > gracePeriod

proc ensure*(registry: PeerRegistry, nodeId: Key, now = Moment.now()): PeerRecord =
  ## Return existing record or create a fresh one. Does not add table membership.
  registry.peers.withValue(nodeId, existing):
    return existing[]
  let record = PeerRecord(
    nodeId: nodeId, lastSeen: now, addedAt: now, lastUsefulAt: Opt.none(Moment)
  )
  registry.peers[nodeId] = record
  record

proc touch*(registry: PeerRegistry, nodeId: Key, now = Moment.now()) =
  ## Bump ``lastSeen`` when the peer is observed again. No-op if missing.
  registry.peers.withValue(nodeId, record):
    record[].lastSeen = now

proc markUseful*(registry: PeerRegistry, nodeId: Key, now = Moment.now()) =
  ## Peer answered a query: refresh usefulness so it survives eviction.
  registry.peers.withValue(nodeId, record):
    record[].lastUsefulAt = Opt.some(now)
    record[].lastSeen = now

proc markUseful*(registry: PeerRegistry, peerId: PeerId, now = Moment.now()) =
  registry.markUseful(peerId.toKey(), now)

proc addMembership*(registry: PeerRegistry, nodeId: Key, tableId: Key) =
  ## Record that ``tableId`` indexes ``nodeId``.
  registry.tablesByPeer.mgetOrPut(nodeId, initHashSet[Key]()).incl(tableId)

proc removeMembership*(registry: PeerRegistry, nodeId: Key, tableId: Key): bool =
  ## Drop one table's reference. When no tables remain, delete the peer row.
  ## Returns true if the peer was removed from the registry entirely.
  registry.tablesByPeer.withValue(nodeId, tables):
    tables[].excl(tableId)
    if tables[].len > 0:
      return false
    registry.tablesByPeer.del(nodeId)
    registry.peers.del(nodeId)
    return true
  # Membership missing but a row may still exist (failed insert path).
  if nodeId in registry.peers and nodeId notin registry.tablesByPeer:
    registry.peers.del(nodeId)
    return true
  false

proc dropPeer*(registry: PeerRegistry, nodeId: Key) =
  ## Remove the peer row and all membership tracking. Callers must also drop
  ## the key from every routing-table bucket that still holds it.
  registry.peers.del(nodeId)
  registry.tablesByPeer.del(nodeId)

func tableIds*(registry: PeerRegistry, nodeId: Key): HashSet[Key] =
  registry.tablesByPeer.getOrDefault(nodeId)

func isReplaceable*(
    registry: PeerRegistry, nodeId: Key, gracePeriod: Duration, now: Moment
): bool =
  let record = registry.get(nodeId).valueOr:
    return false
  record.isReplaceable(gracePeriod, now)

func isReplaceable*(
    registry: PeerRegistry, peerId: PeerId, gracePeriod: Duration, now: Moment
): bool =
  registry.isReplaceable(peerId.toKey(), gracePeriod, now)
