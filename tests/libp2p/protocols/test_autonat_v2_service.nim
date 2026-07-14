# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils, chronos, metrics
import
  ../../../libp2p/[
    builders,
    switch,
    observedaddrmanager,
    protocols/connectivity/autonatv2/types,
    protocols/connectivity/autonatv2/service,
    protocols/connectivity/autonatv2/mockclient,
    nameresolving/nameresolver,
    nameresolving/mockresolver,
    utils/future,
  ]
import ../../tools/[unittest, futures, crypto]

proc createSwitch(
    autonatV2Service: Opt[AutonatV2Service] = Opt.none(AutonatV2Service),
    withAutonat = true,
    maxConnsPerPeer = 1,
    maxConns = 100,
    nameResolver: NameResolver = nil,
): Switch =
  var builder = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()], false)
    .withTcpTransport()
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withMaxConnections(maxConns)
    .withYamux()
    .withNoise()
    .withNameResolver(nameResolver)

  if withAutonat:
    builder = builder.withNAT(autonatConfig(AutonatV2))

  var switch = builder.build()

  autonatV2Service.withValue(s):
    switch.add(s)

  return switch

proc createSwitches(n: int): seq[Switch] =
  var switches: seq[Switch]
  for i in 0 ..< n:
    switches.add(createSwitch())
  switches

proc startAll(switches: seq[Switch]) {.async.} =
  await allFuturesRaising(switches.mapIt(it.start()))

proc stopAll(switches: seq[Switch]) {.async.} =
  await allFuturesRaising(switches.mapIt(it.stop()))

proc startAndConnect(switch: Switch, switches: seq[Switch]) {.async.} =
  await switch.start()

  await switches.startAll()

  for peer in switches:
    await switch.connect(peer.peerInfo.peerId, peer.peerInfo.addrs)

proc newService(
    reachability: NetworkReachability,
    expectedDials = 3,
    config: AutonatV2ServiceConfig = AutonatV2ServiceConfig.new(),
): (AutonatV2Service, AutonatV2ClientMock) =
  let client =
    case reachability
    of Reachable:
      AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = expectedDials,
      )
    of NotReachable:
      AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: NotReachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.EDialError),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = expectedDials,
      )
    of Unknown:
      AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Unknown,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.EDialError),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = expectedDials,
      )
  (AutonatV2Service.new(rng(), client = client, config = config), client)

const ObservedAddrQuorum = 3

const AutonatV2ReachabilityConfidenceMetric =
  "libp2p_autonat_v2_reachability_confidence"

proc reachabilityConfidence(reachability: NetworkReachability): float64 =
  libp2p_autonat_v2_reachability_confidence.valueByName(
    AutonatV2ReachabilityConfidenceMetric, [$reachability]
  )

suite "AutonatV2 Service":
  teardown:
    checkTrackers()

  asyncTest "Reachability unknown before starting switch":
    let (service, _) = newService(NetworkReachability.Reachable)
    discard createSwitch(Opt.some(service))
    check service.networkReachability == NetworkReachability.Unknown

  asyncTest "Peer must be reachable":
    let
      (service, _) = newService(NetworkReachability.Reachable)
      switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() >= 0.3:
        awaiter.completeOnce()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)
    await awaiter

    check service.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 0.3

    await switch.stop()
    await switches.stopAll()

  asyncTest "Peer must be not reachable":
    let
      (service, client) = newService(NetworkReachability.NotReachable)
      switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    await switch.startAndConnect(switches)
    await client.finished

    check service.networkReachability == NetworkReachability.NotReachable
    check reachabilityConfidence(NotReachable) == 0.3

    await switch.stop()
    await switches.stopAll()

  asyncTest "Peer must be not reachable and then reachable":
    let (service, client) = newService(
      NetworkReachability.NotReachable,
      expectedDials = 6,
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    let switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    let notReachableObserved = newFuture[void]()
    let reachableObserved = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and
          confidence.get() >= 0.3:
        notReachableObserved.completeOnce()

        client.response = AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
            # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
        )

      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() >= 0.3:
        reachableObserved.completeOnce()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)

    await notReachableObserved
    await reachableObserved

    check service.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 0.3

    await client.finished

    await switch.stop()
    await switches.stopAll()

  asyncTest "Peer must be reachable when one connected peer has autonat disabled":
    let (service, _) = newService(
      NetworkReachability.Reachable,
      expectedDials = 3,
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 2
      ),
    )

    let switch = createSwitch(Opt.some(service))
    var switches = createSwitches(2)
    switches.add(createSwitch(withAutonat = false))

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter.completeOnce()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)
    await awaiter

    check service.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 1

    await switch.stop()
    await switches.stopAll()

  asyncTest "Unknown answers must be ignored":
    let (service, client) = newService(
      NetworkReachability.NotReachable,
      expectedDials = 6,
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    let switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and
          confidence.get() >= 0.3:
        if not awaiter.finished:
          client.response = AutonatV2Response(
            reachability: Unknown,
            dialResp: DialResponse(
              status: ResponseStatus.Ok,
              dialStatus: Opt.some(DialStatus.EDialError),
              addrIdx: Opt.some(0.AddrIdx),
            ),
          )
          awaiter.complete()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)
    await awaiter

    check service.networkReachability == NetworkReachability.NotReachable
    check reachabilityConfidence(NotReachable) == 0.3

    await client.finished

    check service.networkReachability == NetworkReachability.NotReachable
    check reachabilityConfidence(NotReachable) == 0.3

    await switch.stop()
    await switches.stopAll()

  asyncTest "Must bypass maxConnectionsPerPeer limit":
    let (service, _) = newService(
      NetworkReachability.Reachable,
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 1
      ),
    )
    let switch1 = createSwitch(Opt.some(service), maxConnsPerPeer = 1)
    let switch2 =
      createSwitch(maxConnsPerPeer = 1, nameResolver = MockResolver.default())

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter.completeOnce()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    switch1.peerInfo.addrs.add(
      [
        MultiAddress.init("/dns4/localhost/").tryGet() &
          switch1.peerInfo.addrs[0][1].tryGet()
      ]
    )

    await switch2.start()
    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await awaiter
    check service.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 1
    await allFuturesRaising(switch1.stop(), switch2.stop())

  asyncTest "Must work when peers ask each other at the same time with max 1 conn per peer":
    let
      (service1, _) = newService(
        NetworkReachability.Reachable,
        config = AutonatV2ServiceConfig.new(
          scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
        ),
      )
      (service2, _) = newService(
        NetworkReachability.Reachable,
        config = AutonatV2ServiceConfig.new(
          scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
        ),
      )
      (service3, _) = newService(
        NetworkReachability.Reachable,
        config = AutonatV2ServiceConfig.new(
          scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
        ),
      )
      switch1 = createSwitch(Opt.some(service1), maxConnsPerPeer = 1)
      switch2 = createSwitch(Opt.some(service2), maxConnsPerPeer = 1)
      switch3 = createSwitch(Opt.some(service3), maxConnsPerPeer = 1)

      awaiter1 = newFuture[void]()
      awaiter2 = newFuture[void]()

    proc statusAndConfidenceHandler1(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter1.completeOnce()

    proc statusAndConfidenceHandler2(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter2.completeOnce()

    service1.setStatusAndConfidenceHandler(statusAndConfidenceHandler1)
    service2.setStatusAndConfidenceHandler(statusAndConfidenceHandler2)
    service3.setStatusAndConfidenceHandler(statusAndConfidenceHandler2)

    await switch1.start()
    await switch2.start()
    await switch3.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    await switch2.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)

    await awaiter1
    await awaiter2

    check service1.networkReachability == NetworkReachability.Reachable
    check service2.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 1

    await allFuturesRaising(switch1.stop(), switch2.stop(), switch3.stop())

  asyncTest "Must work for one peer when two peers ask each other at the same time with max 1 conn per peer":
    let
      (service1, _) = newService(
        NetworkReachability.Reachable,
        config = AutonatV2ServiceConfig.new(
          scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
        ),
      )
      (service2, _) = newService(
        NetworkReachability.Reachable,
        config = AutonatV2ServiceConfig.new(
          scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
        ),
      )

    let switch1 = createSwitch(Opt.some(service1), maxConnsPerPeer = 1)
    let switch2 = createSwitch(Opt.some(service2), maxConnsPerPeer = 1)

    let awaiter1 = newFuture[void]()

    proc statusAndConfidenceHandler1(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter1.completeOnce()

    service1.setStatusAndConfidenceHandler(statusAndConfidenceHandler1)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    try:
      # We allow a temp conn for the peer to dial us. It could use this conn to just connect to us and not dial.
      # We don't care if it fails at this point or not. But this conn must be closed eventually.
      # Bellow we check that there's only one connection between the peers
      await switch2.connect(
        switch1.peerInfo.peerId, switch1.peerInfo.addrs, reuseConnection = false
      )
    except CatchableError:
      discard

    await awaiter1

    check service1.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 1

    # Make sure remote peer can't create a connection to us
    check switch1.connManager.connCount(switch2.peerInfo.peerId) == 1

    await allFuturesRaising(switch1.stop(), switch2.stop())

  asyncTest "Must work with low maxConnections":
    let (service, _) = newService(
      NetworkReachability.Reachable,
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 1
      ),
    )

    let switch = createSwitch(Opt.some(service), maxConns = 4)
    var switches = createSwitches(4)

    var awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        awaiter.completeOnce()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch.start()
    await switches.startAll()

    await switch.connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)

    await awaiter

    await switch.connect(switches[2].peerInfo.peerId, switches[2].peerInfo.addrs)
    await switch.connect(switches[3].peerInfo.peerId, switches[3].peerInfo.addrs)
    await switches[3].connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    # switch1 is now full, should stick to last observation
    awaiter = newFuture[void]()
    await service.start(switch)

    await sleepAsync(100.millis)

    check service.networkReachability == NetworkReachability.Reachable
    check reachabilityConfidence(Reachable) == 1

    await switch.stop()
    await switches.stopAll()

  asyncTest "Peer must not ask an incoming peer":
    let (service, _) = newService(
      NetworkReachability.Reachable,
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    let switch1 = createSwitch(Opt.some(service))
    let switch2 = createSwitch()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      fail()

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    await sleepAsync(250.milliseconds)

    await allFuturesRaising(switch1.stop(), switch2.stop())

  asyncTest "Handler must receive the dial-back address on Reachable":
    let
      (service, client) = newService(NetworkReachability.Reachable)
      switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    let awaiter = newFuture[Opt[MultiAddress]]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() >= 0.3:
        awaiter.completeOnce(dialBackAddr)

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)
    let capturedAddr = await awaiter
    await client.finished

    check service.networkReachability == NetworkReachability.Reachable
    check capturedAddr.isSome()
    check capturedAddr.get() == client.allTestAddrs[^1][0]

    await switch.stop()
    await switches.stopAll()

  asyncTest "Handler must receive the attempted address on NotReachable":
    let
      (service, client) = newService(NetworkReachability.NotReachable)
      switch = createSwitch(Opt.some(service))
    var switches = createSwitches(3)

    let awaiter = newFuture[Opt[MultiAddress]]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability,
        confidence: Opt[float],
        dialBackAddr: Opt[MultiAddress],
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and
          confidence.get() >= 0.3:
        awaiter.completeOnce(dialBackAddr)

    service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)
    await switch.startAndConnect(switches)
    let capturedAddr = await awaiter
    await client.finished

    check service.networkReachability == NetworkReachability.NotReachable
    check capturedAddr.isSome()
    check capturedAddr.get() == client.allTestAddrs[^1][0]

    await switch.stop()
    await switches.stopAll()

  asyncTest "Observed addresses must be included in dial request candidates":
    let
      (service, client) = newService(
        NetworkReachability.Reachable,
        expectedDials = 1,
        config = AutonatV2ServiceConfig.new(enableDialableCandidates = true),
      )
      switch = createSwitch(Opt.some(service))
      switches = @[createSwitch()]

    # Simulate identify reports from other peers: the same public address
    # must be observed at least quorum times to become a candidate.
    let observedAddr = MultiAddress.init("/ip4/8.8.8.8/tcp/4040").tryGet()
    for _ in 0 ..< ObservedAddrQuorum:
      discard switch.peerStore.identify.observedAddrManager.addObservation(observedAddr)

    await switch.startAndConnect(switches)
    await client.finished

    let tcpPart = switch.peerInfo.listenAddrs[0][1].tryGet()
    let guessed = concat(MultiAddress.init("/ip4/8.8.8.8").tryGet(), tcpPart).tryGet()
    check guessed in client.allTestAddrs[0]
    # Ensure that the guessed IP is preferred over the observed IP when both are dialable.
    check client.allTestAddrs[0].find(guessed) <
      client.allTestAddrs[0].find(observedAddr)

    # Observed address is kept as a fallback
    check observedAddr in client.allTestAddrs[0]

    for ma in switch.peerInfo.addrs:
      check ma in client.allTestAddrs[0]

    await switch.stop()
    await switches.stopAll()

  asyncTest "Dial request must fall back to the guessed dialable address when the observed IP reaches quorum but the port does not":
    # High minConfidence keeps the node Unknown for the whole test, so the
    # address mapper stays inactive: candidates can only come from the
    # observed addresses.
    # Each connection triggers identify: after quorum of them the observed IP
    # reaches quorum (ports are ephemeral, only the IP is stable), so the next
    # ask must include the guessed dialable address (observed IP + listen port).
    let
      (service, client) = newService(
        NetworkReachability.Reachable,
        expectedDials = ObservedAddrQuorum + 1,
        config = AutonatV2ServiceConfig.new(
          minConfidence = 0.9, enableDialableCandidates = true
        ),
      )
      switch = createSwitch(Opt.some(service))
      switches = createSwitches(ObservedAddrQuorum + 1)

    await switch.startAndConnect(switches)
    await client.finished

    let tcpPart = switch.peerInfo.listenAddrs[0][1].tryGet()
    let expected =
      concat(MultiAddress.init("/ip4/127.0.0.1").tryGet(), tcpPart).tryGet()

    # Before the quorum (first quorum asks), only the listen addresses are sent.
    for reqAddrs in client.allTestAddrs[0 ..< ObservedAddrQuorum]:
      check reqAddrs == switch.peerInfo.listenAddrs

    # The first ask after the quorum is reached must contain the guessed
    # dialable address.
    check expected in client.allTestAddrs[ObservedAddrQuorum]

    # Make sure the guessed dialable address is not in the peer's listen addresses
    check expected notin switch.peerInfo.addrs

    await switch.stop()
    await switches.stopAll()

  asyncTest "Dialable candidates are not added when disabled":
    # Same setup as the mirror test above (node kept Unknown via high
    # minConfidence, so the address mapper stays inactive), but with
    # enableDialableCandidates left to its default of false. The node then
    # advertises only its listen addresses, so every dial request must be
    # exactly the listen addresses: no guessed or observed candidate is added,
    # even after the observed IP reaches quorum.
    let
      (service, client) = newService(
        NetworkReachability.Reachable,
        expectedDials = ObservedAddrQuorum + 1,
        config = AutonatV2ServiceConfig.new(minConfidence = 0.9),
      )
      switch = createSwitch(Opt.some(service))
      switches = createSwitches(ObservedAddrQuorum + 1)

    await switch.startAndConnect(switches)
    await client.finished

    for reqAddrs in client.allTestAddrs:
      check reqAddrs == switch.peerInfo.listenAddrs

    await switch.stop()
    await switches.stopAll()
