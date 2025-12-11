# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
{.used.}

import results, chronos
import ../../../libp2p/[switch, builders]
import ../../../libp2p/protocols/kad_disco

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
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
