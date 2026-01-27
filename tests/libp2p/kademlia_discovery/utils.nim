# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronicles, chronos, results
import ../../../libp2p/[switch, builders]
import ../../../libp2p/protocols/[kad_disco, kademlia]
import ../../tools/crypto

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(rng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

proc setupKad*(
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): KademliaDiscovery =
  let switch = createSwitch()
  let config = KadDHTConfig.new(
    validator,
    selector,
    timeout = chronos.seconds(1),
    cleanupProvidersInterval = chronos.milliseconds(100),
    providerExpirationInterval = chronos.seconds(1),
    republishProvidedKeysInterval = chronos.milliseconds(50),
  )
  let kad = KademliaDiscovery.new(switch, bootstrapNodes, config)
  switch.mount(kad)
  kad

proc setupKads*(
    count: int,
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): seq[KademliaDiscovery] =
  var kads: seq[KademliaDiscovery]
  for i in 0 ..< count:
    kads.add(setupKad(validator, selector, bootstrapNodes))
  kads

proc connect*(kad1, kad2: KademliaDiscovery) {.async.} =
  discard kad1.rtable.insert(kad2.switch.peerInfo.peerId)
  discard kad2.rtable.insert(kad1.switch.peerInfo.peerId)
  kad1.switch.peerStore[AddressBook][kad2.switch.peerInfo.peerId] =
    kad2.switch.peerInfo.addrs
  kad2.switch.peerStore[AddressBook][kad1.switch.peerInfo.peerId] =
    kad1.switch.peerInfo.addrs
