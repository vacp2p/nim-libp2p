# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, times]
import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo, extended_peer_record]
import ./kademlia
import ./kademlia_discovery/[types, registrar, advertiser, discoverer, randomfind]

export types, randomfind

logScope:
  topics = "kad-disco"

proc refreshSearchTables*(disco: KademliaDiscovery) {.async: (raises: []).} =
  #TODO fix this

  return

proc refreshSelfSignedPeerRecord(disco: KademliaDiscovery) {.async: (raises: []).} =
  let updateRes = catch:
    await disco.switch.peerInfo.update()
  if updateRes.isErr:
    error "Failed to update peer info", error = updateRes.error.msg
    return

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

  let putRes = catch:
    await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error.msg

proc maintainSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

proc maintainSearchTables(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh search tables", disco.config.bucketRefreshTime:
    await disco.refreshSearchTables()

proc new*(
    T: typedesc[KademliaDiscovery],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
    client: bool = false,
    #TODO change this to logos codec and also the hard-coded values in kademlia
    codec: string = KadCodec,
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
    discoverer: Discoverer.new(),
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
      else:
        error "Unhandled kad-dht message type", msg = msg
        return
  return kad

method start*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  disco.selfSignedLoop = disco.maintainSelfSignedPeerRecord()
  disco.discovererLoop = disco.maintainSearchTables()
  disco.advertiserLoop = disco.runAdvertiserLoop()

  await procCall start(KadDHT(disco))

  info "Kademlia Discovery started"

method stop*(disco: KademliaDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  await procCall stop(KadDHT(disco))

  disco.selfSignedLoop.cancelSoon()
  disco.selfSignedLoop = nil

  disco.maintenanceLoop.cancelSoon()
  disco.maintenanceLoop = nil

  disco.republishLoop.cancelSoon()
  disco.republishLoop = nil

  disco.expiredLoop.cancelSoon()
  disco.expiredLoop = nil

  disco.discovererLoop.cancelSoon()
  disco.discovererLoop = nil

  disco.advertiserLoop.cancelSoon()
  disco.advertiserLoop = nil

  disco.started = false
