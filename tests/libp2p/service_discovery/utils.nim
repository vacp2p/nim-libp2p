# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/sequtils
import chronos, chronicles, results
import
  ../../../libp2p/
    [peerid, switch, builders, crypto/crypto, extended_peer_record, multiaddress]
import ../../../libp2p/protocols/[service_discovery, kademlia]
import ../../../libp2p/protocols/kademlia/protobuf
import
  ../../../libp2p/protocols/service_discovery/[types, registrar, routing_table_manager]
import ../../tools/[crypto]

export protobuf, types, registrar, routing_table_manager

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

proc makePeerId*(): PeerId =
  PeerId.init(PrivateKey.random(rng[]).get()).get()

proc makeServiceId*(id: byte = 1'u8): ServiceId =
  @[id, 2'u8, 3, 4]

proc makeServiceInfo*(id: string = "blabla"): ServiceInfo =
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
    privateKey: PrivateKey = PrivateKey.random(rng[]).get(),
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

proc fillCache*(registrar: Registrar, n: int, now: Moment) =
  for i in 0 ..< n:
    let ad = makeAdvertisement($i)
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

proc createSwitch*(): Switch =
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

proc makeMockDiscovery*(
    discoConfig: ServiceDiscoveryConfig =
      ServiceDiscoveryConfig.new(kRegister = 3, bucketsCount = 16)
): ServiceDiscovery =
  let switch = createSwitch()
  ServiceDiscovery.new(
    switch,
    bootstrapNodes = @[],
    discoConfig = discoConfig,
    config = KadDHTConfig.new(
      ExtEntryValidator(),
      ExtEntrySelector(),
      timeout = 1.secs,
      cleanupProvidersInterval = 100.millis,
      providerExpirationInterval = 1.secs,
      republishProvidedKeysInterval = 50.millis,
    ),
  )

proc makeDisco*(
    fReturn: int = 3, advertExpiry: int64 = -1, safetyParam: float64 = -1
): ServiceDiscovery =
  var config = ServiceDiscoveryConfig.new(kRegister = 3, bucketsCount = 16)
  config.fReturn = fReturn
  if advertExpiry >= 0:
    config.advertExpiry = advertExpiry.secs
  if safetyParam >= 0:
    config.safetyParam = safetyParam
  makeMockDiscovery(config)

# --- Legacy helpers for existing tests ---

proc setupDiscovery*(
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): ServiceDiscovery =
  let switch = createSwitch()
  let config = KadDHTConfig.new(
    validator,
    selector,
    timeout = 1.secs,
    cleanupProvidersInterval = 100.millis,
    providerExpirationInterval = 1.secs,
    republishProvidedKeysInterval = 50.millis,
  )
  let disco = ServiceDiscovery.new(switch, bootstrapNodes, config)
  switch.mount(disco)
  disco

proc setupDiscos*(
    count: int,
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): seq[ServiceDiscovery] =
  var discos: seq[ServiceDiscovery]
  for i in 0 ..< count:
    discos.add(setupDiscovery(validator, selector, bootstrapNodes))
  discos

proc connect*(disco1, disco2: ServiceDiscovery) {.async.} =
  discard disco1.rtable.insert(disco2.switch.peerInfo.peerId)
  discard disco2.rtable.insert(disco1.switch.peerInfo.peerId)
  disco1.switch.peerStore[AddressBook][disco2.switch.peerInfo.peerId] =
    disco2.switch.peerInfo.addrs
  disco2.switch.peerStore[AddressBook][disco1.switch.peerInfo.peerId] =
    disco1.switch.peerInfo.addrs

proc populateRoutingTable*(disco: ServiceDiscovery, count: int) =
  for i in 0 ..< count:
    discard disco.rtable.insert(makePeerId())

proc populateAdvTable*(disco: ServiceDiscovery, serviceId: ServiceId) =
  for i in 0 ..< disco.discoConfig.kRegister:
    discard disco.rtable.insert(makePeerId())
  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

proc populateSearchTable*(
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerId]
) =
  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )
  for peer in peers:
    disco.rtManager.insertPeer(serviceId, peer.toKey())
