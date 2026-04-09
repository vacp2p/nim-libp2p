# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos, chronicles, results
import ../kademlia/[types, routingtable]
import ../kademlia
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
): bool {.raises: [].} =
  manager.serviceStatus.withValue(serviceId, currentStatus):
    if status == currentStatus[]:
      return false
    manager.serviceStatus[serviceId] = Both
    return true

  let serviceTable = RoutingTable.new(
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
) {.raises: [].} =
  manager.serviceStatus.withValue(serviceId, currentStatus):
    if currentStatus[] == status:
      manager.tables.del(serviceId)
      manager.serviceStatus.del(serviceId)
      manager.updateServiceTablesMetrics()
      return

    if currentStatus[] == Both:
      manager.serviceStatus[serviceId] = if status == Interest: Provided else: Interest

proc getTable*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): Opt[RoutingTable] {.raises: [].} =
  let res = catch:
    manager.tables[serviceId]
  let table = res.valueOr:
    return Opt.none(RoutingTable)

  return Opt.some(table)

proc insertPeer*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, peerKey: Key
): bool {.raises: [].} =
  manager.tables.withValue(serviceId, table):
    let inserted = table[].insert(peerKey)
    if inserted:
      cd_service_table_insertions.inc()
      manager.updateServiceTablesMetrics()
    return inserted
  do:
    return false

proc hasService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): bool {.raises: [].} =
  return serviceId in manager.tables

proc refreshAllTables*(
    manager: ServiceRoutingTableManager, kad: KadDHT
) {.async: (raises: [CancelledError]).} =
  let tables: seq[RoutingTable] = manager.tables.values.toSeq()
  for serviceTable in tables:
    let refreshRes = catch:
      await kad.refreshTable(serviceTable)
    if refreshRes.isErr:
      error "failed to refresh service routing table", error = refreshRes.error.msg

proc count*(manager: ServiceRoutingTableManager): int {.inline, raises: [].} =
  return manager.tables.len

proc serviceIds*(
    manager: ServiceRoutingTableManager
): seq[ServiceId] {.inline, raises: [].} =
  return manager.tables.keys.toSeq()

proc clear*(manager: ServiceRoutingTableManager) {.inline, raises: [].} =
  manager.tables.clear()
  manager.serviceStatus.clear()
