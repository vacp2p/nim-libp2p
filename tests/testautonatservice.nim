# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos
import unittest2
import ../libp2p/[builders,
                  switch,
                  services/autonatservice]
import ./helpers
import stubs/autonatstub

proc createSwitch(): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()

  return builder.build()

suite "Autonat Service":
  teardown:
    checkTrackers()

  asyncTest "Autonat Service Private Reachability test":

    let switch1 = createSwitch()
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatStub = AutonatStub.new(expectedDials = 3)
    autonatStub.returnSuccess = false

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))
    switch1.addService(autonatService)

    check autonatService.networkReachability() == NetworkReachability.Unknown

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.NotReachable

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Autonat Service Public Reachability test":

    let switch1 = createSwitch()
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatStub = AutonatStub.new(expectedDials = 3)
    autonatStub.returnSuccess = true

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))
    check autonatService.networkReachability() == NetworkReachability.Unknown
    switch1.addService(autonatService)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.Reachable

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Autonat Service Full Reachability test":

    let switch1 = createSwitch()
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatStub = AutonatStub.new(expectedDials = 6)
    autonatStub.returnSuccess = false

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))

    switch1.addService(autonatService)

    let awaiter = Awaiter.new()

    proc f(networkReachability: NetworkReachability) {.gcsafe, async.} =
       if networkReachability == NetworkReachability.NotReachable:
         autonatStub.returnSuccess = true
         awaiter.finished.complete()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.onNewStatuswithMaxConfidence(f)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter.finished

    check autonatService.networkReachability() == NetworkReachability.NotReachable

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.Reachable

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

asyncTest "Autonat Service setup and stop twice":

  let switch = createSwitch()
  let autonatService = AutonatService.new(AutonatStub.new(expectedDials = 0), newRng(), some(1.seconds))

  check (await autonatService.setup(switch)) == true
  check (await autonatService.setup(switch)) == false

  check (await autonatService.stop(switch)) == true
  check (await autonatService.stop(switch)) == false

  await allFuturesThrowing(switch.stop())