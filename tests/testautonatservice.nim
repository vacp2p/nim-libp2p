# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos, metrics
import unittest2
import ../libp2p/[builders,
                  switch,
                  protocols/connectivity/autonat/client,
                  protocols/connectivity/autonat/service]
import ./helpers
import stubs/autonatclientstub

proc createSwitch(autonatSvc: Service = nil, withAutonat = true, maxConnsPerPeer = 1, maxConns = 100): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withMaxConnections(maxConns)
    .withMplex()
    .withNoise()

  if withAutonat:
    builder = builder.withAutonat()

  if autonatSvc != nil:
    builder = builder.withServices(@[autonatSvc])

  return builder.build()

suite "Autonat Service":
  teardown:
    checkTrackers()

  asyncTest "Peer must be not reachable":

    let autonatClientStub = AutonatClientStub.new(expectedDials = 3)
    autonatClientStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatClientStub, newRng())

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

    await autonatClientStub.finished

    check autonatService.networkReachability() == NetworkReachability.NotReachable
    check libp2p_autonat_reachability_confidence.value(["NotReachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Peer must be reachable":

    let autonatService = AutonatService.new(AutonatClient.new(), newRng(), some(1.seconds))

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() >= 0.3:
        if not awaiter.finished:
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

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Peer must be not reachable and then reachable":

    let autonatClientStub = AutonatClientStub.new(expectedDials = 6)
    autonatClientStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatClientStub, newRng(), some(1.seconds))

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and confidence.get() >= 0.3:
        if not awaiter.finished:
          autonatClientStub.answer = Reachable
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

    await autonatClientStub.finished

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Peer must be reachable when one connected peer has autonat disabled":

    let autonatService = AutonatService.new(AutonatClient.new(), newRng(), some(1.seconds), maxQueueSize = 2)

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch(withAutonat = false)
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter.finished:
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

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Unknown answers must be ignored":

    let autonatClientStub = AutonatClientStub.new(expectedDials = 6)
    autonatClientStub.answer = NotReachable

    let autonatService = AutonatService.new(autonatClientStub, newRng(), some(1.seconds), maxQueueSize = 3)

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and confidence.get() >= 0.3:
        if not awaiter.finished:
          autonatClientStub.answer = Unknown
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
    check libp2p_autonat_reachability_confidence.value(["NotReachable"]) == 1/3

    await autonatClientStub.finished

    check autonatService.networkReachability() == NetworkReachability.NotReachable
    check libp2p_autonat_reachability_confidence.value(["NotReachable"]) == 1/3

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Calling setup and stop twice must work":

    let switch = createSwitch()
    let autonatService = AutonatService.new(AutonatClientStub.new(expectedDials = 0), newRng(), some(1.seconds))

    check (await autonatService.setup(switch)) == true
    check (await autonatService.setup(switch)) == false

    check (await autonatService.stop(switch)) == true
    check (await autonatService.stop(switch)) == false

    await allFuturesThrowing(switch.stop())

  asyncTest "Must bypass maxConnectionsPerPeer limit":
    let autonatService = AutonatService.new(AutonatClient.new(), newRng(), some(1.seconds), maxQueueSize = 1)

    let switch1 = createSwitch(autonatService, maxConnsPerPeer = 0)
    let switch2 = createSwitch(maxConnsPerPeer = 0)

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter.finished:
          awaiter.complete()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

    await awaiter

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop())

  asyncTest "Must work when peers ask each other at the same time with max 1 conn per peer":
    let autonatService1 = AutonatService.new(AutonatClient.new(), newRng(), some(500.millis), maxQueueSize = 3)
    let autonatService2 = AutonatService.new(AutonatClient.new(), newRng(), some(500.millis), maxQueueSize = 3)
    let autonatService3 = AutonatService.new(AutonatClient.new(), newRng(), some(500.millis), maxQueueSize = 3)

    let switch1 = createSwitch(autonatService1, maxConnsPerPeer = 0)
    let switch2 = createSwitch(autonatService2, maxConnsPerPeer = 0)
    let switch3 = createSwitch(autonatService2, maxConnsPerPeer = 0)

    let awaiter1 = newFuture[void]()
    let awaiter2 = newFuture[void]()
    let awaiter3 = newFuture[void]()

    proc statusAndConfidenceHandler1(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter1.finished:
          awaiter1.complete()

    proc statusAndConfidenceHandler2(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter2.finished:
          awaiter2.complete()

    check autonatService1.networkReachability() == NetworkReachability.Unknown
    check autonatService2.networkReachability() == NetworkReachability.Unknown

    autonatService1.statusAndConfidenceHandler(statusAndConfidenceHandler1)
    autonatService2.statusAndConfidenceHandler(statusAndConfidenceHandler2)

    await switch1.start()
    await switch2.start()
    await switch3.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    await switch2.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)

    await awaiter1
    await awaiter2

    check autonatService1.networkReachability() == NetworkReachability.Reachable
    check autonatService2.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop())

  asyncTest "Must work for one peer when two peers ask each other at the same time with max 1 conn per peer":
    let autonatService1 = AutonatService.new(AutonatClient.new(), newRng(), some(500.millis), maxQueueSize = 3)
    let autonatService2 = AutonatService.new(AutonatClient.new(), newRng(), some(500.millis), maxQueueSize = 3)

    let switch1 = createSwitch(autonatService1, maxConnsPerPeer = 0)
    let switch2 = createSwitch(autonatService2, maxConnsPerPeer = 0)

    let awaiter1 = newFuture[void]()

    proc statusAndConfidenceHandler1(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter1.finished:
          awaiter1.complete()

    check autonatService1.networkReachability() == NetworkReachability.Unknown

    autonatService1.statusAndConfidenceHandler(statusAndConfidenceHandler1)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    try:
      # We allow a temp conn for the peer to dial us. It could use this conn to just connect to us and not dial.
      # We don't care if it fails at this point or not. But this conn must be closed eventually.
      # Bellow we check that there's only one connection between the peers
      await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs, reuseConnection = false)
    except CatchableError:
      discard

    await awaiter1

    check autonatService1.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 1

    # Make sure remote peer can't create a connection to us
    check switch1.connManager.connCount(switch2.peerInfo.peerId) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop())

  asyncTest "Must work with low maxConnections":
    let autonatService = AutonatService.new(AutonatClient.new(), newRng(), some(1.seconds), maxQueueSize = 1)

    let switch1 = createSwitch(autonatService, maxConns = 4)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()
    let switch5 = createSwitch()

    var awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and confidence.get() == 1:
        if not awaiter.finished:
          awaiter.complete()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()
    await switch5.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

    await awaiter

    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)
    await switch5.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    # switch1 is now full, should stick to last observation
    awaiter = newFuture[void]()
    await autonatService.run(switch1)
    await awaiter

    check autonatService.networkReachability() == NetworkReachability.Reachable
    check libp2p_autonat_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop())

  asyncTest "Peer must not ask an incoming peer":
    let autonatService = AutonatService.new(AutonatClient.new(), newRng())

    let switch1 = createSwitch(autonatService)
    let switch2 = createSwitch()

    proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      fail()

    check autonatService.networkReachability() == NetworkReachability.Unknown

    autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    await sleepAsync(500.milliseconds)

    await allFuturesThrowing(
      switch1.stop(), switch2.stop())
