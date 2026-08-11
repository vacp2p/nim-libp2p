# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../libp2p/[multiaddress, multicodec, observedaddrmanager, switch]
import ../tools/[unittest, switch_builder, multiaddress]

proc newManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): ObservedAddrManager =
  ObservedAddrManager.new(
    ObservedAddrManagerConfig(maxSize: maxSize, minCount: minCount)
  )

proc newStartedManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): ObservedAddrManager =
  let observedAddrManager = newManager(maxSize, minCount)
  observedAddrManager.start()
  observedAddrManager

suite "ObservedAddrManager":
  teardown:
    checkTrackers()

  asyncTest "Calculate the most oberserved IP correctly":
    let observedAddrManager = newStartedManager(minCount = 3)

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
    let observedAddrManager = newStartedManager(minCount = 3)
    let mostObservedIP4AndPort = MultiAddress.init("/ip4/1.2.3.4/tcp/1").get()

    check:
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.guessDialableAddr(MultiAddress.init("/ip4/0.0.0.0").get()) ==
        MultiAddress.init("/ip4/1.2.3.4").get()

  asyncTest "an address which is not a direct IP address with a transport is rejected":
    let
      observedAddrManager = newStartedManager(maxSize = 2, minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check observedAddrManager.addObservation(observed)

    # the window is small: junk must neither be counted nor evict the good entry
    for _ in 0 ..< 4:
      check:
        not observedAddrManager.addObservation(ma("/dns4/example.com/tcp/1"))
        not observedAddrManager.addObservation(ma("/ip4/1.2.3.4"))
        not observedAddrManager.addObservation(ma("/ip4/1.2.3.4/tcp/1/p2p-circuit"))

    check observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

  asyncTest "a threshold below one is raised to one":
    let
      observedAddrManager = newStartedManager(maxSize = 0, minCount = 0)
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    check:
      observedAddrManager.addObservation(firstObserved)
      observedAddrManager.addObservation(lastObserved)
      observedAddrManager.getMostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "a stopped manager rejects observations until it starts again":
    let
      observedAddrManager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    observedAddrManager.start()
    check observedAddrManager.addObservation(observed)

    observedAddrManager.stop()
    check:
      not observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

    observedAddrManager.start()
    check:
      observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

    observedAddrManager.stop()

  asyncTest "start and stop are idempotent":
    let
      observedAddrManager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    observedAddrManager.stop()
    check not observedAddrManager.isStarted()

    observedAddrManager.start()
    observedAddrManager.start()

    check:
      observedAddrManager.isStarted()
      observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts() == @[observed]

    observedAddrManager.stop()
    observedAddrManager.stop()

    check:
      not observedAddrManager.isStarted()
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

  asyncTest "a manager which never started rejects observations":
    let
      observedAddrManager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check:
      not observedAddrManager.isStarted()
      not observedAddrManager.addObservation(observed)
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

    observedAddrManager.start()

    check observedAddrManager.addObservation(observed)

    observedAddrManager.stop()

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

    await switch.start()
    defer:
      await switch.stop()

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
    let observedAddrManager = newManager(maxSize = 1, minCount = 1)

    {.push warning[Deprecated]: off.}
    let switch = makeStandardSwitchBuilder(ma("/memorytransport/*"))
      .withObservedAddrManager(observedAddrManager)
      .build()
    {.pop.}

    check:
      switch.observedAddrManager == observedAddrManager
      switch.peerStore.identify.observedAddrManager == observedAddrManager

  asyncTest "the switch starts and stops the manager":
    let switch = makeStandardSwitch(ma("/memorytransport/*"))

    check not switch.observedAddrManager.isStarted()

    await switch.start()
    check switch.observedAddrManager.isStarted()

    await switch.stop()
    check not switch.observedAddrManager.isStarted()

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
