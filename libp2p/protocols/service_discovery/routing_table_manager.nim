# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos, chronicles, results
import ../kademlia
import ../kademlia/[types, routing_table]
import ./types
import ./service_discovery_metrics

logScope:
  topics = "service-disco service-routing-tables"

type
  ServiceStatus* = enum
    Interest = 0
    Provided = 1
    Both = 2

  ServiceRoutingTableManager* = ref object
    tables*: Table[ServiceId, RoutingTable]
    serviceStatus*: Table[ServiceId, ServiceStatus]

proc updateServiceTablesMetrics(manager: ServiceRoutingTableManager) {.raises: [].} =
  cd_service_tables_count.set(manager.tables.len.float64)
  var totalPeers = 0
  for table in manager.tables.values:
    for bucket in table.buckets:
      totalPeers += bucket.peers.len
  cd_service_table_peers.set(totalPeers.float64)

proc new*(T: typedesc[ServiceRoutingTableManager]): T =
  T(
    tables: initTable[ServiceId, RoutingTable](),
    serviceStatus: initTable[ServiceId, ServiceStatus](),
  )

proc addService*(
    manager: ServiceRoutingTableManager,
    serviceId: ServiceId,
    mainRoutingTable: RoutingTable,
    replication: int,
    bucketsCount: int,
    status: ServiceStatus,
): bool =
  if serviceId in manager.serviceStatus:
    if status == manager.serviceStatus.getOrDefault(serviceId):
      return false

    manager.serviceStatus[serviceId] = Both
    return true

  var serviceTable = RoutingTable.new(
    serviceId,
    config =
      RoutingTableConfig.new(replication = replication, maxBuckets = bucketsCount),
  )

  for bucket in mainRoutingTable.buckets:
    for peer in bucket.peers:
      discard serviceTable.insert(peer.nodeId)

  manager.tables[serviceId] = serviceTable
  manager.serviceStatus[serviceId] = status
  manager.updateServiceTablesMetrics()
  return true

proc removeService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, status: ServiceStatus
) =
  if serviceId notin manager.serviceStatus:
    return

  if manager.serviceStatus.getOrDefault(serviceId) == status:
    manager.tables.del(serviceId)
    manager.serviceStatus.del(serviceId)
    manager.updateServiceTablesMetrics()
    return

  if manager.serviceStatus.getOrDefault(serviceId) == Both:
    if status == Interest:
      manager.serviceStatus[serviceId] = Provided
    elif status == Provided:
      manager.serviceStatus[serviceId] = Interest

proc getTable*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): Opt[RoutingTable] =
  let res = catch:
    manager.tables[serviceId]
  let table = res.valueOr:
    return Opt.none(RoutingTable)

  return Opt.some(table)

proc insertPeer*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, peerKey: Key
) =
  let res = catch:
    manager.tables[serviceId]
  var table = res.valueOr:
    return

  let inserted = table.insert(peerKey)
  if inserted:
    cd_service_table_insertions.inc()
    manager.updateServiceTablesMetrics()

proc hasService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): bool {.inline.} =
  ## Check if routing table exists for a service
  serviceId in manager.tables

proc refreshAllTables*(
    manager: ServiceRoutingTableManager, kad: KadDHT
) {.async: (raises: [CancelledError]).} =
  let tables = manager.tables.values.toSeq()

  for serviceTable in tables:
    let refreshRes = catch:
      await kad.refreshTable(serviceTable)
    if refreshRes.isErr:
      error "failed to refresh service routing table", error = refreshRes.error.msg

proc count*(manager: ServiceRoutingTableManager): int {.inline.} =
  return manager.tables.len

proc serviceIds*(manager: ServiceRoutingTableManager): seq[ServiceId] {.inline.} =
  return manager.tables.keys.toSeq()

proc clear*(manager: ServiceRoutingTableManager) {.inline.} =
  manager.tables.clear()
  manager.serviceStatus.clear()
  manager.updateServiceTablesMetrics()
