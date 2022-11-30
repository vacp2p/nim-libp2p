# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos

import unittest2
import ./helpers
import ../libp2p/[builders,
                  switch,
                  services/autonatservice]
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

    let autonatService = AutonatService.new(autonatStub)
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

    check autonatService.networkReachability() == NetworkReachability.Private

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Autonat Service Public Reachability test":

    let switch1 = createSwitch()
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatStub = AutonatStub.new(expectedDials = 3)
    autonatStub.returnSuccess = true

    let autonatService = AutonatService.new(autonatStub)
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

    check autonatService.networkReachability() == NetworkReachability.Public

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Autonat Service Full Reachability test":

    let switch1 = createSwitch()
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatStub = AutonatStub.new(expectedDials = 6)
    autonatStub.returnSuccess = false

    let autonatService = AutonatService.new(autonatStub)

    switch1.addService(autonatService)

    let awaiter = Awaiter.new()

    proc f(networkReachability: NetworkReachability) {.gcsafe, async.} =
       if networkReachability == NetworkReachability.Private:
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

    check autonatService.networkReachability() == NetworkReachability.Private

    await awaiter.finished

    await autonatService.run(switch1)

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.Public

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  # asyncTest "IPFS Hope Punching test":
  #   let switch1 = createAutonatSwitch()

  #   switch1.addService(HPService.new())

  #   await switch1.start()

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN").get(),
  #     @[MultiAddress.init("/ip4/139.178.91.71/tcp/4001").get()]
  #   )

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt").get(),
  #     @[MultiAddress.init("/ip4/145.40.118.135/tcp/4001").get()]
  #   )

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ").get(),
  #     @[MultiAddress.init("/ip4/104.131.131.82/tcp/4001").get()]
  #   )

  #   await sleepAsync(20.seconds)

  #   await allFuturesThrowing(
  #     switch1.stop())