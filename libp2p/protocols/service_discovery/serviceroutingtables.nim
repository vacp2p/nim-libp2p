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
    lock*: AsyncLock

template withLock(
    manager: ServiceRoutingTableManager, body: untyped
): untyped {.dirty.} =
  ## Acquires the manager lock, executes `body`, then releases the lock.
  ## The lock is always released even if `body` raises or returns early.
  await manager.lock.acquire()
  try:
    body
  finally:
    try:
      manager.lock.release()
    except AsyncLockError as exc:
      raiseAssert exc.msg

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
    lock: newAsyncLock(),
  )

proc addService*(
    manager: ServiceRoutingTableManager,
    serviceId: ServiceId,
    mainRoutingTable: RoutingTable,
    replication: int,
    bucketsCount: int,
    status: ServiceStatus,
): Future[bool] {.async: (raises: [CancelledError]).} =
  withLock(manager):
    manager.serviceStatus.withValue(serviceId, currentStatus):
      if status == currentStatus[]:
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
) {.async: (raises: [CancelledError]).} =
  withLock(manager):
    if serviceId notin manager.serviceStatus:
      return

    let currentStatus = manager.serviceStatus.getOrDefault(serviceId)
    if currentStatus == status:
      manager.tables.del(serviceId)
      manager.serviceStatus.del(serviceId)
      manager.updateServiceTablesMetrics()
      return

    if currentStatus == Both:
      manager.serviceStatus[serviceId] = if status == Interest: Provided else: Interest

proc getTable*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): Future[Opt[RoutingTable]] {.async: (raises: [CancelledError]).} =
  withLock(manager):
    let res = catch:
      manager.tables[serviceId]
    let table = res.valueOr:
      return Opt.none(RoutingTable)

    return Opt.some(table)

proc insertPeer*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, peerKey: Key
): Future[bool] {.async: (raises: [CancelledError]).} =
  withLock(manager):
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
): Future[bool] {.async: (raises: [CancelledError]).} =
  withLock(manager):
    return serviceId in manager.tables

proc refreshAllTables*(
    manager: ServiceRoutingTableManager, kad: KadDHT
) {.async: (raises: [CancelledError]).} =
  var tablesCopy: seq[RoutingTable]

  withLock(manager):
    tablesCopy = manager.tables.values.toSeq()

  for serviceTable in tablesCopy.mitems:
    let refreshRes = catch:
      await kad.refreshTable(serviceTable)
    if refreshRes.isErr:
      error "failed to refresh service routing table", error = refreshRes.error.msg

proc count*(
    manager: ServiceRoutingTableManager
): Future[int] {.async: (raises: [CancelledError]).} =
  withLock(manager):
    return manager.tables.len

proc serviceIds*(
    manager: ServiceRoutingTableManager
): Future[seq[ServiceId]] {.async: (raises: [CancelledError]).} =
  withLock(manager):
    return manager.tables.keys.toSeq()

proc clear*(manager: ServiceRoutingTableManager) {.async: (raises: [CancelledError]).} =
  withLock(manager):
    manager.tables.clear()
    manager.serviceStatus.clear()
