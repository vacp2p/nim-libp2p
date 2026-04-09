# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sets
import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo, extended_peer_record]
import ./kademlia
import ./kademlia_discovery/types as kad_types
import ./kademlia_discovery/randomfind
import ./service_discovery/types as cap_types

export kad_types, randomfind, cap_types

logScope:
  topics = "kad-disco"

const ServiceDiscoveryCodec = "/logos/service-discovery/1.0.0"

proc refreshSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  await disco.switch.peerInfo.update()
  let extPeerRecord = disco.record().valueOr:
    error "Failed to create signed extended peer record", error
    return

  let encodedSR = extPeerRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = disco.switch.peerInfo.peerId.toKey()

  debug "Publishing Signed XPR",
    peerId = disco.switch.peerInfo.peerId, serviceCount = disco.services.len

  let putRes = await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error

proc maintainSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

proc new*(
    T: typedesc[KademliaDiscovery],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext,
    client: bool = false,
    codec: string = ServiceDiscoveryCodec,
    services: seq[ServiceInfo] = @[],
    discoConf: KademliaDiscoveryConfig = KademliaDiscoveryConfig.new(),
    xprPublishing: bool = true,
): T {.raises: [].} =
  let rtable = RoutingTable.new(
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
    services: toHashSet(services),
    discoConf: discoConf,
    xprPublishing: xprPublishing,
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

      kad_messages_received.inc(labelValues = [$msg.msgType])
      kad_message_bytes_received.inc(buf.len.int64, labelValues = [$msg.msgType])

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
        trace "Unimplemented"
        return
      of MessageType.register:
        trace "Unimplemented"
        return

  return kad

method start*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  await procCall start(KadDHT(disco))

  if disco.xprPublishing:
    disco.selfSignedLoop = disco.maintainSelfSignedPeerRecord()

  info "Kademlia Discovery started"

method stop*(disco: KademliaDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  if not disco.selfSignedLoop.isNil:
    disco.selfSignedLoop.cancelSoon()
    disco.selfSignedLoop = nil

  if not disco.serviceTableLoop.isNil:
    disco.serviceTableLoop.cancelSoon()
    disco.serviceTableLoop = nil

  if not disco.advertiseLoop.isNil:
    disco.advertiseLoop.cancelSoon()
    disco.advertiseLoop = nil

  if not disco.registrarCacheLoop.isNil:
    disco.registrarCacheLoop.cancelSoon()
    disco.registrarCacheLoop = nil
  await procCall stop(KadDHT(disco))
