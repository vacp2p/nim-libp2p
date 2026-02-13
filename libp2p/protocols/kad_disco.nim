# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sets
import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo, extended_peer_record]
import ./kademlia
import ./kademlia_discovery/types as kad_types
import ./kademlia_discovery/randomfind
import ./capability_discovery/types as cap_types
import ./capability_discovery/[registrar, advertiser, discoverer, serviceroutingtables]

export kad_types, randomfind, cap_types, registrar, advertiser, discoverer

logScope:
  topics = "kad-disco"

const CapabilityDiscoveryCodec = "/logos/capability-discovery/1.0.0"

proc refreshSelfSignedPeerRecord(disco: KademliaDiscovery) {.async: (raises: []).} =
  let extPeerRecord = (await disco.record()).valueOr:
    error "Failed to create signed extended peer record", error
    return

  let encodedSR = extPeerRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = disco.switch.peerInfo.peerId.toKey()

  let putRes = catch:
    await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error.msg

proc maintainSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

proc maintainRegistrarCache(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "prune expired advertisements",
    chronos.seconds(int(disco.discoConf.advertExpiry)):
    disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry.uint64)

proc maintainTables(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh service routing tables", disco.config.bucketRefreshTime:
    await disco.serviceRoutingTables.refreshAllTables(disco)

proc new*(
    T: typedesc[KademliaDiscovery],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
    client: bool = false,
    codec: string = CapabilityDiscoveryCodec,
    services: seq[ServiceInfo] = @[],
    discoConf: KademliaDiscoveryConfig = KademliaDiscoveryConfig.new(),
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )

  let kad = T(
    rng: rng,
    switch: switch,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
    registrar: Registrar.new(),
    advertiser: Advertiser.new(),
    serviceRoutingTables: ServiceRoutingTableManager.new(),
    services: toHashSet(services),
    discoConf: discoConf,
  )

  # Fill up buckets with initial bootstrap nodes
  kad.updatePeers(bootstrapNodes)

  kad.codec = codec
  if client:
    return kad

  kad.handler = proc(
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
          debug "Read error when handling kademlia RPC", conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      case msg.msgType
      of MessageType.findNode:
        await kad.handleFindNode(conn, msg)
      of MessageType.putValue:
        await kad.handlePutValue(conn, msg)
      of MessageType.getValue:
        await kad.handleGetValue(conn, msg)
      of MessageType.addProvider:
        await kad.handleAddProvider(conn, msg)
      of MessageType.getProviders:
        await kad.handleGetProviders(conn, msg)
      of MessageType.ping:
        await kad.handlePing(conn, msg)
      of MessageType.getAds:
        await kad.handleGetAds(conn, msg)
      of MessageType.register:
        await kad.handleRegister(conn, msg)

  return kad

method start*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  disco.selfSignedLoop = disco.maintainSelfSignedPeerRecord()
  disco.registrarCacheLoop = disco.maintainRegistrarCache()
  disco.serviceTableLoop = disco.maintainTables()

  await procCall start(KadDHT(disco))

  info "Kademlia Discovery started"

method stop*(disco: KademliaDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  await procCall stop(KadDHT(disco))

  if not disco.selfSignedLoop.isNil:
    disco.selfSignedLoop.cancelSoon()
    disco.selfSignedLoop = nil

  if not disco.registrarCacheLoop.isNil:
    disco.registrarCacheLoop.cancelSoon()
    disco.registrarCacheLoop = nil

  if not disco.serviceTableLoop.isNil:
    disco.serviceTableLoop.cancelSoon()
    disco.serviceTableLoop = nil

  if not disco.advertiseLoop.isNil:
    disco.advertiseLoop.cancelSoon()
    disco.advertiseLoop = nil

  disco.started = false
