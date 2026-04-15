# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, sequtils]
import chronos, chronicles, results
import
  ../../../libp2p/
    [peerid, switch, builders, crypto/crypto, extended_peer_record, multiaddress]
import ../../../libp2p/protocols/[service_discovery, kademlia]
import ../../../libp2p/protocols/kademlia/protobuf
import ../../../libp2p/protocols/service_discovery/[types, registrar]
import ../../tools/[crypto]

export protobuf, types, registrar

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
    tInit: 1_000_000,
    tMod: 2_000_000,
    tWaitFor: 3000,
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
    serviceId: ServiceId = makeServiceId(), addrs: seq[MultiAddress] = @[]
): Advertisement =
  let privateKey = PrivateKey.random(rng[]).get()
  let peerId = PeerId.init(privateKey).get()
  let extRecord = ExtendedPeerRecord(
    peerId: peerId,
    seqNo: getTime().toUnix().uint64,
    addresses: addrs.mapIt(AddressInfo(address: it)),
    services: @[],
  )
  SignedExtendedPeerRecord.init(privateKey, extRecord).get()

proc makeAdvertisementWithSeqNo*(
    privateKey: PrivateKey, seqNo: uint64, addrs: seq[MultiAddress] = @[]
): Advertisement =
  let peerId = PeerId.init(privateKey).get()
  let extRecord = ExtendedPeerRecord(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addrs.mapIt(AddressInfo(address: it)),
    services: @[],
  )
  SignedExtendedPeerRecord.init(privateKey, extRecord).get()

proc fillCache*(registrar: Registrar, n: int, now: uint64) =
  for i in 0 ..< n:
    let ad = makeAdvertisement(serviceId = makeServiceId(i.byte))
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
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
  )

proc makeDisco*(
    fReturn: int = 3, advertExpiry: float64 = -1, safetyParam: float64 = -1
): ServiceDiscovery =
  var config = ServiceDiscoveryConfig.new(kRegister = 3, bucketsCount = 16)
  config.fReturn = fReturn
  if advertExpiry >= 0:
    config.advertExpiry = chronos.seconds(int(advertExpiry))
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
    timeout = chronos.seconds(1),
    cleanupProvidersInterval = chronos.milliseconds(100),
    providerExpirationInterval = chronos.seconds(1),
    republishProvidedKeysInterval = chronos.milliseconds(50),
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
