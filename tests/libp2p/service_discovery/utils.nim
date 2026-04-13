# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronicles, chronos, results
import ../../../libp2p/[switch, builders, crypto/crypto]
import ../../../libp2p/protocols/[service_discovery, kademlia]
import ../../../libp2p/protocols/kademlia/protobuf
import ../../tools/[crypto]

export protobuf

proc makeTicket*(): Ticket =
  Ticket(
    advertisement: @[1'u8, 2, 3, 4],
    tInit: 1_000_000,
    tMod: 2_000_000,
    tWaitFor: 3000,
    expiresAt: 0,
    nonce: @[],
    signature: @[],
  )

proc signedTicket*(privateKey: PrivateKey): Ticket =
  var t = makeTicket()
  let res = t.sign(privateKey)
  doAssert res.isOk(), "sign failed in test helper"
  t

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(rng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

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
