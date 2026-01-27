# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results, chronos
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

template setupKadSwitch*(
    validator: untyped, selector: untyped, bootstrapNodes: untyped = @[]
): untyped =
  let switch = createSwitch()
  let kad = KademliaDiscovery.new(
    switch,
    bootstrapNodes,
    config = KadDHTConfig.new(
      validator,
      selector,
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
  )

  switch.mount(kad)
  await switch.start()
  (switch, kad)
