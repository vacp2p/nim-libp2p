# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results, sets, sequtils, std/times
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo, extended_peer_record]
import ./kademlia
import
  ./service_discovery/
    [random_find, types, routing_table_manager, advertiser, registrar, discoverer]

export random_find, types, discoverer

logScope:
  topics = "service-discovery"

proc refreshSelfSignedPeerRecord(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  await disco.switch.peerInfo.update()

  let
    peerInfo: PeerInfo = disco.switch.peerInfo
    services: seq[ServiceInfo] = disco.services.toSeq()

  let extPeerRecord = SignedExtendedPeerRecord.init(
    peerInfo.privateKey,
    ExtendedPeerRecord(
      peerId: peerInfo.peerId,
      seqNo: getTime().toUnix().uint64,
      addresses: peerInfo.addrs.mapIt(AddressInfo(address: it)),
      services: services,
    ),
  ).valueOr:
    error "Failed to create signed peer record", error
    return

  let encodedSR = extPeerRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = disco.switch.peerInfo.peerId.toKey()

  let putRes = await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error

proc maintainSelfSignedPeerRecord(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

proc maintainRegistrar(disco: ServiceDiscovery) {.async: (raises: [CancelledError]).} =
  heartbeat "prune expired advertisements", disco.discoConfig.advertExpiry:
    disco.registrar.pruneExpiredAds(disco.discoConfig.advertExpiry.seconds.uint64)

proc maintainServiceTables(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh service routing tables", disco.config.bucketRefreshTime:
    await disco.rtManager.refreshAllTables(disco)

proc startAdvertising*(disco: ServiceDiscovery, service: ServiceInfo): bool =
  ## Include this service in the set of services this node provides.

  return disco.services.containsOrIncl(service)

proc stopAdvertising*(disco: ServiceDiscovery, service: ServiceInfo): bool =
  ## Exclude this service from the set of services this node provides.

  return disco.services.missingOrExcl(service)

proc new*(
    T: typedesc[ServiceDiscovery],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
    client: bool = false,
    codec: string = ExtendedServiceDiscoveryCodec,
    services: seq[ServiceInfo] = @[],
    discoConfig: ServiceDiscoveryConfig = ServiceDiscoveryConfig.new(),
    xprPublishing: bool = true,
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )

  let disco = ServiceDiscovery(
    rng: rng,
    switch: switch,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
    rtManager: ServiceRoutingTableManager.new(),
    advertiser: Advertiser.new(),
    registrar: Registrar.new(),
    services: toHashSet(services),
    discoConfig: discoConfig,
    xprPublishing: xprPublishing,
  )

  # Fill up buckets with initial bootstrap nodes
  disco.updatePeers(bootstrapNodes)

  disco.codec = codec
  if client:
    return disco

  disco.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await conn.close()
    while not conn.atEof:
      let buf =
        try:
          await conn.readLp(MaxMsgSize)
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling service-discovery RPC",
            conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      case msg.msgType
      of MessageType.findNode:
        await disco.handleFindNode(conn, msg)
      of MessageType.putValue:
        await disco.handlePutValue(conn, msg)
      of MessageType.getValue:
        await disco.handleGetValue(conn, msg)
      of MessageType.addProvider:
        await disco.handleAddProvider(conn, msg)
      of MessageType.getProviders:
        await disco.handleGetProviders(conn, msg)
      of MessageType.ping:
        await disco.handlePing(conn, msg)
      of MessageType.getAds:
        await disco.handleGetAds(conn, msg)
      of MessageType.register:
        await disco.handleRegister(conn, msg)

  return disco

method start*(disco: ServiceDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  await procCall start(KadDHT(disco))

  disco.selfSignedPeerRecordLoop = disco.maintainSelfSignedPeerRecord()
  disco.pruneExpiredAdsLoop = disco.maintainRegistrar()
  disco.refreshServiceTablesLoop = disco.maintainServiceTables()

  info "Service Discovery started"

method stop*(disco: ServiceDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  disco.advertiser.clear()
  disco.selfSignedPeerRecordLoop.cancelSoon()
  disco.selfSignedPeerRecordLoop = nil

  disco.pruneExpiredAdsLoop.cancelSoon()
  disco.pruneExpiredAdsLoop = nil

  disco.refreshServiceTablesLoop.cancelSoon()
  disco.refreshServiceTablesLoop = nil

  await procCall stop(KadDHT(disco))
