# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos, chronicles, results
import ../../[switch, peerinfo, peeraddrpolicy]
import ../kademlia
import ../kademlia/[types, routing_table]
import ./[types, service_discovery_metrics]

logScope:
  topics = "service-disco service-routing-tables"

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
  # Fast path: service already exists
  manager.serviceStatus.withValue(serviceId, currentStatus):
    # No change needed
    if currentStatus[] == status or currentStatus[] == Both:
      return false

    # Merge states
    manager.serviceStatus[serviceId] = Both
    manager.updateServiceTablesMetrics()
    return true

  # Create new routing table
  var rtable = RoutingTable.new(
    serviceId,
    config = RoutingTableConfig.new(
      replication = replication, maxBuckets = bucketsCount, selfIdPreHashed = true
    ),
    localNodeId = Opt.some(mainRoutingTable.localNodeId),
  )

  # Seed from main table
  for bucket in mainRoutingTable.buckets:
    for peer in bucket.peers:
      discard rtable.insert(peer.nodeId)

  manager.tables[serviceId] = rtable
  manager.serviceStatus[serviceId] = status

  manager.updateServiceTablesMetrics()

  if not manager.onServiceTableCreated.isNil:
    manager.onServiceTableCreated(serviceId)

  return true

proc removeService*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId, status: ServiceStatus
) =
  manager.serviceStatus.withValue(serviceId, currentStatus):
    if currentStatus[] == status:
      manager.tables.del(serviceId)
      manager.serviceStatus.del(serviceId)
      manager.updateServiceTablesMetrics()
      return

    if (currentStatus[], status) == (Both, Interest):
      currentStatus[] = Provided
    elif (currentStatus[], status) == (Both, Provided):
      currentStatus[] = Interest

proc getTable*(
    manager: ServiceRoutingTableManager, serviceId: ServiceId
): Opt[RoutingTable] =
  let res = catch:
    manager.tables[serviceId]
  let table = res.valueOr:
    return Opt.none(RoutingTable)

  return Opt.some(table)

proc insertPeer*(
    disco: ServiceDiscovery, serviceId: ServiceId, peerInfo: PeerInfo
): bool =
  let table = disco.rtManager.getTable(serviceId).valueOr:
    return false

  let addressBook = disco.switch.peerStore[AddressBook]
  let addrs = disco.config.addressPolicy.filterAddrs(peerInfo.addrs)
  if addrs.len == 0:
    return false
  if not addressBook.hasIpDiversity(
    table, peerInfo.peerId, addrs, disco.config.limits.maxPeersPerIp,
    disco.config.limits.maxPeersPerIpv4Subnet, disco.config.limits.maxPeersPerIpv6Subnet,
  ):
    return false

  result = table.insert(peerInfo.peerId)
  if result:
    addressBook.extend(peerInfo.peerId, addrs, AddressConfidence.Low)
    cd_service_table_insertions.inc()
    disco.rtManager.updateServiceTablesMetrics()

proc hasService*(manager: ServiceRoutingTableManager, serviceId: ServiceId): bool =
  ## Check if routing table exists for a service
  serviceId in manager.tables

proc hasPeerInServiceTable*(
    disco: ServiceDiscovery, serviceId: ServiceId, peerId: PeerId
): bool =
  let table = disco.rtManager.getTable(serviceId).valueOr:
    return false
  peerId.toKey() in table.allKeys()

proc refreshAllTables*(
    manager: ServiceRoutingTableManager, kad: KadDHT
) {.async: (raises: [CancelledError]).} =
  let tables = manager.tables.values.toSeq()

  for rtable in tables:
    await kad.refreshTable(rtable)

proc count*(manager: ServiceRoutingTableManager): int =
  return manager.tables.len

proc serviceIds*(manager: ServiceRoutingTableManager): seq[ServiceId] =
  return manager.tables.keys.toSeq()

proc clear*(manager: ServiceRoutingTableManager) =
  manager.tables.clear()
  manager.serviceStatus.clear()
  manager.updateServiceTablesMetrics()
