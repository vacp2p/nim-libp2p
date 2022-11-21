# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## The switch is the core of libp2p, which brings together the
## transports, the connection manager, the upgrader and other
## parts to allow programs to use libp2p

import chronos
import unittest2
import ./helpers
import ../libp2p/[builders,
                  switch,
                  services/hpservice]

proc createAutonatSwitch(): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()
    .build()

suite "Hope Punching":
  teardown:
    checkTrackers()
  asyncTest "Hope Punching test":
    let switch1 = createAutonatSwitch()
    let switch2 = createAutonatSwitch()
    let switch3 = createAutonatSwitch()
    let switch4 = createAutonatSwitch()

    switch1.addService(HPService.new())

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    await switch3.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    await switch4.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    await sleepAsync(500.milliseconds)

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())