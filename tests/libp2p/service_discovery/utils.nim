# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, chronicles, results, sequtils, tables
import
  ../../../libp2p/[
    builders,
    crypto/crypto,
    extended_peer_record,
    multiaddress,
    peerid,
    protocols/kademlia,
    protocols/kademlia/protobuf,
    protocols/service_discovery,
    protocols/service_discovery/registrar,
    protocols/service_discovery/routing_table_manager,
    protocols/service_discovery/types,
    switch,
  ]
import ../../tools/[crypto, switch_builder, multiaddress]

export protobuf, registrar, routing_table_manager, types

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

proc randomKey*(): PrivateKey =
  PrivateKey.random(rng()).get()

proc randomPeerId*(): PeerId =
  PeerId.init(randomKey()).get()

proc makeServiceId*(id: byte = 1'u8): ServiceId =
  var buf = newSeq[byte](IdLength)
  buf[0] = id
  return buf

proc makeServiceInfo*(id: string = "test-service"): ServiceInfo =
  ServiceInfo(id: id, data: @[1, 2, 3, 4])

proc makeTicket*(): Ticket =
  Ticket(
    advertisement: @[1'u8, 2, 3, 4],
    tInit: Moment.init(1_000_000, Second),
    tMod: Moment.init(2_000_000, Second),
    tWaitFor: 3000.secs,
    signature: @[],
  )

proc signedTicket*(privateKey: PrivateKey): Ticket =
  var t = makeTicket()
  let res = t.sign(privateKey)
  doAssert res.isOk(), "sign failed in test helper"
  t

proc makeMultiAddress*(ip: string): MultiAddress =
  MultiAddress.init("/ip4/" & ip & "/tcp/9000").get()

proc makeAdvertisement*(
    serviceId: string = $1,
    privateKey: PrivateKey = PrivateKey.random(rng()).get(),
    addrs: seq[MultiAddress] = @[],
    seqNo: uint64 = Moment.now().epochSeconds.uint64,
): Advertisement =
  let peerId = PeerId.init(privateKey).get()
  let extRecord = ExtendedPeerRecord(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addrs.mapIt(AddressInfo(address: it)),
    services: @[makeServiceInfo(serviceId)],
  )
  SignedExtendedPeerRecord.init(privateKey, extRecord).get()

proc createSwitch*(privateKey: Opt[PrivateKey] = Opt.none(PrivateKey)): Switch =
  makeStandardSwitchBuilder(TcpAutoAddress).withPrivateKey(privateKey).build()

proc testKadDHTConfig(): KadDHTConfig =
  KadDHTConfig.new(
    ExtEntryValidator(),
    ExtEntrySelector(),
    timeout = 1.secs,
    cleanupProvidersInterval = 100.millis,
    providerExpirationInterval = 1.secs,
    republishProvidedKeysInterval = 50.millis,
  )

proc setupServiceDiscoveryNode*(
    discoConfig: ServiceDiscoveryConfig = ServiceDiscoveryConfig.new(),
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    xprPublishing: bool = true,
    services: seq[ServiceInfo] = @[],
    client: bool = false,
    privateKey: Opt[PrivateKey] = Opt.none(PrivateKey),
): ServiceDiscovery =
  let switch = createSwitch(privateKey)
  let node = ServiceDiscovery.new(
    switch,
    bootstrapNodes = bootstrapNodes,
    config = testKadDHTConfig(),
    rng = rng(),
    services = services,
    client = client,
    discoConfig = discoConfig,
    xprPublishing = xprPublishing,
  )
  if not client:
    switch.mount(node)
  node

proc setupServiceDiscoveryNodes*(
    count: int,
    discoConfig: ServiceDiscoveryConfig = ServiceDiscoveryConfig.new(),
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    xprPublishing: bool = true,
): seq[ServiceDiscovery] =
  var nodes: seq[ServiceDiscovery]
  for i in 0 ..< count:
    nodes.add(setupServiceDiscoveryNode(discoConfig, bootstrapNodes, xprPublishing))
  nodes

proc connect*(disco1, disco2: ServiceDiscovery) {.async.} =
  ## Bidirectionally connect two ServiceDiscovery instances.
  discard disco1.rtable.insert(disco2.switch.peerInfo.peerId)
  discard disco2.rtable.insert(disco1.switch.peerInfo.peerId)
  disco1.switch.peerStore[AddressBook][disco2.switch.peerInfo.peerId] =
    disco2.switch.peerInfo.addrs
  disco2.switch.peerStore[AddressBook][disco1.switch.peerInfo.peerId] =
    disco1.switch.peerInfo.addrs

proc hasPeer*(rtable: RoutingTable, peerKey: Key): bool =
  rtable.buckets.anyIt(it.peers.anyIt(it.nodeId == peerKey))

proc populateRoutingTable*(disco: ServiceDiscovery, count: int) =
  for i in 0 ..< count:
    discard disco.rtable.insert(randomPeerId())

proc populateAdvertisementTable*(disco: ServiceDiscovery, serviceId: ServiceId) =
  for i in 0 ..< disco.discoConfig.kRegister:
    discard disco.rtable.insert(randomPeerId())
  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

proc getAdsInCache*(disco: ServiceDiscovery, serviceId: ServiceId): seq[Advertisement] =
  disco.registrar.cache.getOrDefault(serviceId, @[])

proc countAdsInCache*(disco: ServiceDiscovery, serviceId: ServiceId): int =
  disco.getAdsInCache(serviceId).len

proc containsPeer*(
    response: Result[seq[Advertisement], string], node: ServiceDiscovery
): bool =
  response.isOk() and response.get().anyIt(
    it.data.peerId == node.switch.peerInfo.peerId
  )
