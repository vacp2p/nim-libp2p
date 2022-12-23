# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[options, math]
import chronos, metrics
import unittest2
import ../libp2p/[builders,
                  switch,
                  services/autonatservice]
import ./helpers
import stubs/autonatstub

proc createSwitch(autonatSvc: Service = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()

  if autonatSvc != nil:
    builder = builder.withServices(@[autonatSvc])

  return builder.build()

suite "Autonat Service":
  teardown:
    checkTrackers()

  asyncTest "Peer must be not reachable":

    let autonatStub = AutonatStub.new(expectedDials = 3)
    autonatStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatStub, newRng())

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

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
    check libp2p_autonat_reachability_confidence.value(["NotReachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Peer must be reachable":

    let autonatStub = AutonatStub.new(expectedDials = 3)
    autonatStub.answer = Reachable

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Peer must be not reachable and then reachable":

    let autonatStub = AutonatStub.new(expectedDials = 6)
    autonatStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and confidence.get() >= 0.3:
        if not awaiter.finished:
          autonatStub.answer = Reachable
          awaiter.complete()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check autonatService.networkReachability() == NetworkReachability.NotReachable
    check libp2p_autonat_reachability_confidence.value(["NotReachable"]) == 0.3

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Unknown answers must be ignored":

    let autonatStub = AutonatStub.new(expectedDials = 6)
    autonatStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds), maxQueueSize = 3)

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and confidence.get() >= 0.3:
        if not awaiter.finished:
          autonatStub.answer = Unknown
          awaiter.complete()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check autonatService.networkReachability() == NetworkReachability.NotReachable
    check almostEqual(libp2p_autonat_reachability_confidence.value(["NotReachable"]), 1/3)

    await autonatStub.finished

    check autonatService.networkReachability() == NetworkReachability.NotReachable
    check almostEqual(libp2p_autonat_reachability_confidence.value(["NotReachable"]), 1/3)

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Calling setup and stop twice must work":

    let switch = createSwitch()
    let autonatService = AutonatService.new(AutonatStub.new(expectedDials = 0), newRng(), some(1.seconds))

    check (await autonatService.setup(switch)) == true
    check (await autonatService.setup(switch)) == false

    check (await autonatService.stop(switch)) == true
    check (await autonatService.stop(switch)) == false

    await allFuturesThrowing(switch.stop())
