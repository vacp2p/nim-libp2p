# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results, sets
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo, extended_peer_record]
import ./kademlia
import
  ./service_discovery/[
    random_find, types, routing_table_manager, advertiser, registrar, discoverer,
    connection,
  ]

export random_find, types, discoverer, advertiser

logScope:
  topics = "service-discovery"

proc refreshSelfSignedPeerRecord(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  let extPeerRecord = disco.record().valueOr:
    error "Failed to create signed extended peer record", error
    return

  let encodedSR = extPeerRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = disco.switch.peerInfo.peerId.toKey()

  debug "Publishing Signed XPR", xpr = $extPeerRecord

  let putRes = await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error

proc maintainSelfSignedPeerRecord(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

proc maintainRegistrar(disco: ServiceDiscovery) {.async: (raises: [CancelledError]).} =
  heartbeat "prune expired advertisements",
    disco.discoConfig.advertExpiry, sleepFirst = true:
    disco.registrar.pruneExpiredAds(disco.discoConfig.advertExpiry)

proc maintainServiceTables(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh service routing tables",
    disco.config.bucketRefreshTime, sleepFirst = true:
    await disco.rtManager.refreshAllTables(disco)

proc new*(
    T: typedesc[ServiceDiscovery],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: Rng,
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
    rpcSem: newAsyncSemaphore(config.limits.maxConcurrentRpcs),
    rtManager: ServiceRoutingTableManager.new(),
    clientMode: client,
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
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await stream.close()
    while not stream.atEof:
      let buf =
        try:
          await stream.readLp(MaxMsgSize)
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling service-discovery RPC",
            stream = stream, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      let msgType = msg.msgType.get(MessageType.putValue)
      case msgType
      of MessageType.findNode:
        await disco.handleFindNode(stream, msg)
      of MessageType.putValue:
        await disco.handlePutValue(stream, msg)
      of MessageType.getValue:
        await disco.handleGetValue(stream, msg)
      of MessageType.addProvider:
        await disco.handleAddProvider(stream, msg)
      of MessageType.getProviders:
        await disco.handleGetProviders(stream, msg)
      of MessageType.ping:
        await disco.handlePing(stream, msg)
      else:
        if msgType in @[MessageType.register, MessageType.getAds]:
          await disco.handleMessage(stream, msg)
        else:
          debug "received invalid message type", msgType = msgType
          return

  return disco

method start*(disco: ServiceDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  await procCall start(KadDHT(disco))

  if disco.xprPublishing:
    disco.selfSignedPeerRecordLoop = disco.maintainSelfSignedPeerRecord()

  for serviceInfo in disco.services:
    disco.addProvidedService(serviceInfo)

  disco.pruneExpiredAdsLoop = disco.maintainRegistrar()
  disco.refreshServiceTablesLoop = disco.maintainServiceTables()
  disco.advertiserMaintenanceLoop = disco.maintainAdvertiser()

  info "Service Discovery started"

method stop*(disco: ServiceDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  disco.advertiser.clear()

  if not disco.selfSignedPeerRecordLoop.isNil():
    disco.selfSignedPeerRecordLoop.cancelSoon()
    disco.selfSignedPeerRecordLoop = nil

  if not disco.pruneExpiredAdsLoop.isNil():
    disco.pruneExpiredAdsLoop.cancelSoon()
    disco.pruneExpiredAdsLoop = nil

  if not disco.refreshServiceTablesLoop.isNil():
    disco.refreshServiceTablesLoop.cancelSoon()
    disco.refreshServiceTablesLoop = nil

  if not disco.advertiserMaintenanceLoop.isNil():
    disco.advertiserMaintenanceLoop.cancelSoon()
    disco.advertiserMaintenanceLoop = nil

  if not disco.localRegistrationLoop.isNil():
    await disco.localRegistrationLoop.cancelAndWait()
    disco.localRegistrationLoop = nil

  await procCall stop(KadDHT(disco))

proc lookup*(
    disco: ServiceDiscovery, service: ServiceInfo
): Future[Result[seq[Advertisement], string]] {.async: (raises: [CancelledError]).} =
  return await disco.lookup(service.id.hashServiceId())
