# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../libp2p/[multiaddress, multicodec, observedaddrmanager, switch]
import ../tools/[unittest, switch_builder, multiaddress]

suite "ObservedAddrManager":
  teardown:
    checkTrackers()

  asyncTest "Calculate the most oberserved IP correctly":
    let observedAddrManager = ObservedAddrManager.new(minCount = 3)

    # Calculate the most oberserved IP4 correctly
    let mostObservedIP4AndPort = MultiAddress.init("/ip4/1.2.3.0/tcp/1").get()
    let maIP4 = MultiAddress.init("/ip4/0.0.0.0/tcp/80").get()

    check:
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.guessDialableAddr(maIP4) == maIP4

      observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.0/tcp/2").get())
      observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.1/tcp/1").get())

      observedAddrManager.guessDialableAddr(maIP4) ==
        MultiAddress.init("/ip4/1.2.3.0/tcp/80").get()
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.getMostObservedProtosAndPorts() == @[mostObservedIP4AndPort]

    # Calculate the most oberserved IP6 correctly
    let mostObservedIP6AndPort = MultiAddress.init("/ip6/::2/tcp/1").get()
    let maIP6 = MultiAddress.init("/ip6/::1/tcp/80").get()

    check:
      observedAddrManager.addObservation(mostObservedIP6AndPort)
      observedAddrManager.addObservation(mostObservedIP6AndPort)

      observedAddrManager.guessDialableAddr(maIP6) == maIP6

      observedAddrManager.addObservation(MultiAddress.init("/ip6/::2/tcp/2").get())
      observedAddrManager.addObservation(MultiAddress.init("/ip6/::3/tcp/1").get())

      observedAddrManager.guessDialableAddr(maIP6) ==
        MultiAddress.init("/ip6/::2/tcp/80").get()
      observedAddrManager.getMostObservedProtosAndPorts().len == 1

      observedAddrManager.addObservation(mostObservedIP6AndPort)

      observedAddrManager.getMostObservedProtosAndPorts() ==
        @[mostObservedIP4AndPort, mostObservedIP6AndPort]

  asyncTest "replace first proto value by most observed when there is only one protocol":
    let observedAddrManager = ObservedAddrManager.new(minCount = 3)
    let mostObservedIP4AndPort = MultiAddress.init("/ip4/1.2.3.4/tcp/1").get()

    check:
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.guessDialableAddr(MultiAddress.init("/ip4/0.0.0.0").get()) ==
        MultiAddress.init("/ip4/1.2.3.4").get()

  asyncTest "an address which names no dialable address is rejected":
    let
      observedAddrManager = ObservedAddrManager.new(maxSize = 2, minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check observedAddrManager.addObservation(observed)

    # a peer reports what it wants, and the window is small: junk must neither
    # be counted nor evict the useful observation
    for _ in 0 ..< 4:
      check:
        not observedAddrManager.addObservation(ma("/dns4/example.com/tcp/1"))
        not observedAddrManager.addObservation(ma("/ip4/1.2.3.4"))

    check observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

  asyncTest "a stopped manager rejects observations until it starts again":
    let
      observedAddrManager = ObservedAddrManager.new(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    await observedAddrManager.start()
    check observedAddrManager.addObservation(observed)

    await observedAddrManager.stop()
    check:
      not observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

    await observedAddrManager.start()
    check:
      observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

    await observedAddrManager.stop()

  asyncTest "start and stop are idempotent":
    let
      observedAddrManager = ObservedAddrManager.new(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    await observedAddrManager.stop()
    check not observedAddrManager.isStarted()

    await observedAddrManager.start()
    await observedAddrManager.start()

    check:
      observedAddrManager.isStarted()
      observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

    await observedAddrManager.stop()
    await observedAddrManager.stop()

    check:
      not observedAddrManager.isStarted()
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

  asyncTest "starting keeps the observations made before the start":
    let
      observedAddrManager = ObservedAddrManager.new(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check observedAddrManager.addObservation(observed)
    await observedAddrManager.start()

    check observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

    await observedAddrManager.stop()

type LifecycleProbe = ref object of Service
  ## Records the state of the manager at the moment the switch starts and stops
  ## the services.
  managerStartedOnServiceStart: bool
  managerStartedOnServiceStop: bool

method setup(self: LifecycleProbe, switch: Switch) {.raises: [].} =
  discard

method start(
    self: LifecycleProbe, switch: Switch
) {.async: (raises: [CancelledError]).} =
  self.managerStartedOnServiceStart = switch.observedAddrManager.isStarted()

method stop(
    self: LifecycleProbe, switch: Switch
) {.async: (raises: [CancelledError]).} =
  self.managerStartedOnServiceStop = switch.observedAddrManager.isStarted()

suite "Switch-owned ObservedAddrManager":
  teardown:
    checkTrackers()

  asyncTest "the switch owns the manager and identify holds the same instance":
    let switch = makeStandardSwitch(ma("/memorytransport/*"))

    check:
      not switch.observedAddrManager.isNil()
      switch.peerStore.identify.observedAddrManager == switch.observedAddrManager

  asyncTest "identify feeds the manager which the switch owns":
    let
      dialer = makeStandardSwitchBuilder(TcpAutoAddress)
        .withObservedAddrManager(ObservedAddrManagerConfig(minCount: 1))
        .build()
      listener = makeStandardSwitch(TcpAutoAddress)

    await allFutures(dialer.start(), listener.start())
    defer:
      await allFutures(dialer.stop(), listener.stop())

    # the dialer identifies the listener, which reports back the address it sees
    await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)

    let observed = dialer.observedAddrManager.getMostObservedProtosAndPorts()
    check:
      observed.len == 1
      observed[0].contains(multiCodec("ip4")).get(false)

  asyncTest "the builder config sets the thresholds":
    let
      switch = makeStandardSwitchBuilder(ma("/memorytransport/*"))
        .withObservedAddrManager(ObservedAddrManagerConfig(maxSize: 2, minCount: 1))
        .build()
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    # minCount is 1, so a single observation is enough
    check:
      switch.observedAddrManager.addObservation(firstObserved)
      switch.observedAddrManager.getMostObservedProtosAndPorts() == @[firstObserved]

    # maxSize is 2, so the third observation drops the first one
    check:
      switch.observedAddrManager.addObservation(lastObserved)
      switch.observedAddrManager.addObservation(lastObserved)
      switch.observedAddrManager.getMostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "the deprecated builder hook still wires the given manager":
    let observedAddrManager = ObservedAddrManager.new(maxSize = 1, minCount = 1)

    {.push warning[Deprecated]: off.}
    let switch = makeStandardSwitchBuilder(ma("/memorytransport/*"))
      .withObservedAddrManager(observedAddrManager)
      .build()
    {.pop.}

    check:
      switch.observedAddrManager == observedAddrManager
      switch.peerStore.identify.observedAddrManager == observedAddrManager

  asyncTest "the manager starts before the services and stops after them":
    let
      switch = makeStandardSwitch(ma("/memorytransport/*"))
      probe = LifecycleProbe()
    switch.services.add(probe)

    await switch.start()
    check switch.observedAddrManager.isStarted()

    await switch.stop()

    check:
      probe.managerStartedOnServiceStart
      probe.managerStartedOnServiceStop
      not switch.observedAddrManager.isStarted()

  asyncTest "stopping the switch drops the observations":
    let
      switch = makeStandardSwitch(ma("/memorytransport/*"))
      observed = ma("/ip4/1.2.3.4/tcp/1")
      listenAddr = ma("/ip4/0.0.0.0/tcp/80")

    await switch.start()

    for _ in 0 ..< 3:
      check switch.observedAddrManager.addObservation(observed)

    check:
      switch.observedAddrManager.getMostObservedProtosAndPorts() == @[observed]
      switch.observedAddrManager.guessDialableAddr(listenAddr) ==
        ma("/ip4/1.2.3.4/tcp/80")

    await switch.stop()

    check:
      switch.observedAddrManager.getMostObservedProtosAndPorts().len == 0
      switch.observedAddrManager.guessDialableAddr(listenAddr) == listenAddr
