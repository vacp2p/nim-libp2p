# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../kademlia/[types, routingtable]
import ../kademlia
import ./types

logScope:
  topics = "cap-disco service-routing-tables"

type ServiceRoutingTableManager* = ref object
  tables*: Table[ServiceId, RoutingTable]

proc new*(T: typedesc[ServiceRoutingTableManager]): T =
  T(tables: initTable[ServiceId, RoutingTable]())

proc addService*(
    manager: ServiceRoutingTableManager,
    serviceId: ServiceId,
    mainRoutingTable: RoutingTable,
    replication: int,
    bucketsCount: int,
) {.raises: [].} =
  ## Create a new routing table for the service

  if serviceId in manager.tables:
    return

  var serviceTable = RoutingTable.new(
    serviceId,
    config =
      RoutingTableConfig.new(replication = replication, maxBuckets = bucketsCount),
  )

  for bucket in mainRoutingTable.buckets:
    for peer in bucket.peers:
      let peerId = peer.nodeId.toPeerId().valueOr:
        continue

      let peerKey = peerId.toKey()

      discard serviceTable.insert(peerKey)

  manager.tables[serviceId] = serviceTable

proc removeService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
) {.raises: [].} =
  ## Remove routing table for a service

  manager.tables.del(serviceId)

proc getTable*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): Opt[RoutingTable] {.raises: [].} =
  ## Get routing table for a service (immutable view)

  let res = catch:
    manager.tables[serviceId]
  let table = res.valueOr:
    return Opt.none(RoutingTable)

  return Opt.some(table)

proc insertPeer*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, peerKey: Key
) {.raises: [].} =
  ## Insert a peer into the service routing table

  let res = catch:
    manager.tables[serviceId]
  var table = res.valueOr:
    return

  discard table.insert(peerKey)
  return

proc hasService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): bool {.raises: [].} =
  ## Check if routing table exists for a service

  serviceId in manager.tables

proc refreshAllTables*(
    manager: ServiceRoutingTableManager, kad: KadDHT
) {.async: (raises: []).} =
  ## Refresh all service routing tables using KadDHT's refreshTable

  for serviceTable in manager.tables.values:
    let refreshRes = catch:
      await kad.refreshTable(serviceTable)
    if refreshRes.isErr:
      error "failed to refresh service routing table", error = refreshRes.error.msg

proc count*(manager: ServiceRoutingTableManager): int {.raises: [].} =
  ## Get number of service routing tables

  manager.tables.len

proc serviceIds*(manager: ServiceRoutingTableManager): seq[ServiceId] {.raises: [].} =
  ## Get all service IDs

  manager.tables.keys.toSeq()

proc clear*(manager: ServiceRoutingTableManager) {.raises: [].} =
  ## Clear all service routing tables

  manager.tables.clear()
