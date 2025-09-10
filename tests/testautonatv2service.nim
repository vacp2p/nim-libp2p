{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# import std/sequtils
import chronos, metrics
import unittest2
import
  ../libp2p/[
    builders,
    switch,
    protocols/connectivity/autonatv2/types,
    # protocols/connectivity/autonatv2/client,
    protocols/connectivity/autonatv2/service,
    protocols/connectivity/autonatv2/mockclient,
  ]
import ../libp2p/nameresolving/[nameresolver, mockresolver]
import ./helpers

proc createSwitch(
    autonatSvc: Service = nil,
    withAutonat = true,
    maxConnsPerPeer = 1,
    maxConns = 100,
    nameResolver: NameResolver = nil,
): Switch =
  var builder = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()], false)
    .withTcpTransport()
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withMaxConnections(maxConns)
    .withYamux()
    .withNoise()

  if withAutonat:
    builder = builder.withAutonatV2()

  if autonatSvc != nil:
    builder = builder.withServices(@[autonatSvc])

  if nameResolver != nil:
    builder = builder.withNameResolver(nameResolver)

  return builder.build()

suite "AutonatV2 Service":
  teardown:
    checkTrackers()

  asyncTest "Peer must be not reachable":
    let client = AutonatV2ClientMock.new(
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialBackError),
          addrIdx: Opt.some(0.AddrIdx),
        ), # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
      ),
      expectedDials = 3,
    )

    let service = AutonatV2Service.new(newRng(), client = client)

    let switch1 = createSwitch(service, withAutonat = false)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    check service.networkReachability == NetworkReachability.Unknown

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await client.finished

    check service.networkReachability == NetworkReachability.NotReachable
    check libp2p_autonat_v2_reachability_confidence.value(["NotReachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop()
    )

  asyncTest "Peer must be reachable":
    let client = AutonatV2ClientMock.new(
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ), # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
      ),
      expectedDials = 3,
    )

    let service = AutonatV2Service.new(newRng(), client = client)

    let switch1 = createSwitch(service, withAutonat = false)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() >= 0.3:
        if not awaiter.finished:
          awaiter.complete()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check service.networkReachability == NetworkReachability.Reachable
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop()
    )

  asyncTest "Peer must be not reachable and then reachable":
    let client = AutonatV2ClientMock.new(
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ), # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
      ),
      expectedDials = 6,
    )

    let service = AutonatV2Service.new(
      newRng(),
      client = client,
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    let switch1 = createSwitch(service, withAutonat = false)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.NotReachable and confidence.isSome() and
          confidence.get() >= 0.3:
        if not awaiter.finished:
          client.response = AutonatV2Response(
            reachability: Reachable,
            dialResp: DialResponse(
              status: ResponseStatus.Ok,
              dialStatus: Opt.some(DialStatus.Ok),
              addrIdx: Opt.some(0.AddrIdx),
            ),
              # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
          )
          awaiter.complete()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check service.networkReachability == NetworkReachability.NotReachable
    check libp2p_autonat_v2_reachability_confidence.value(["NotReachable"]) == 0.3

    await client.finished

    check service.networkReachability == NetworkReachability.Reachable
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop()
    )

  asyncTest "Peer must be reachable when one connected peer has autonat disabled":
    let client = AutonatV2ClientMock.new(
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ), # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
      ),
      expectedDials = 3,
    )

    let service = AutonatV2Service.new(
      newRng(),
      client = client,
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 2
      ),
    )

    let switch1 = createSwitch(service, withAutonat = false)
    let switch2 = createSwitch(withAutonat = false)
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter.finished:
          awaiter.complete()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check service.networkReachability == NetworkReachability.Reachable
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop()
    )

  asyncTest "Unknown answers must be ignored":
    let client = AutonatV2ClientMock.new(
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ), # addrs: Opt.none(MultiAddress), # this will be inferred from sendDialRequest
      ),
      expectedDials = 6,
    )

    let service = AutonatV2Service.new(
      newRng(),
      client = client,
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    let switch1 = createSwitch(service, withAutonat = false)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
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

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await awaiter

    check service.networkReachability == NetworkReachability.NotReachable
    check libp2p_autonat_v2_reachability_confidence.value(["NotReachable"]) == 0.3

    await client.finished

    check service.networkReachability == NetworkReachability.NotReachable
    check libp2p_autonat_v2_reachability_confidence.value(["NotReachable"]) == 0.3

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop()
    )

  asyncTest "Calling setup and stop twice must work":
    let switch = createSwitch()
    let service = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: NotReachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.EDialError),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds)),
    )

    check (await service.setup(switch)) == true
    check (await service.setup(switch)) == false

    check (await service.stop(switch)) == true
    check (await service.stop(switch)) == false

    await allFuturesThrowing(switch.stop())

  asyncTest "Must bypass maxConnectionsPerPeer limit":
    let service = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 1
      ),
    )

    let switch1 = createSwitch(service, maxConnsPerPeer = 0)
    let switch2 =
      createSwitch(maxConnsPerPeer = 0, nameResolver = MockResolver.default())

    let awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter.finished:
          awaiter.complete()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

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
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 1
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "Must work when peers ask each other at the same time with max 1 conn per peer":
    let service1 = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
      ),
    )

    let service2 = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
      ),
    )

    let service3 = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
      ),
    )

    let switch1 = createSwitch(service1, maxConnsPerPeer = 0)
    let switch2 = createSwitch(service2, maxConnsPerPeer = 0)
    let switch3 = createSwitch(service2, maxConnsPerPeer = 0)

    let awaiter1 = newFuture[void]()
    let awaiter2 = newFuture[void]()
    let awaiter3 = newFuture[void]()

    proc statusAndConfidenceHandler1(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter1.finished:
          awaiter1.complete()

    proc statusAndConfidenceHandler2(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter2.finished:
          awaiter2.complete()

    check service1.networkReachability == NetworkReachability.Unknown
    check service2.networkReachability == NetworkReachability.Unknown

    service1.statusAndConfidenceHandler(statusAndConfidenceHandler1)
    service2.statusAndConfidenceHandler(statusAndConfidenceHandler2)

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
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop())

  asyncTest "Must work for one peer when two peers ask each other at the same time with max 1 conn per peer":
    let service1 = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
      ),
    )

    let service2 = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(500.millis), maxQueueSize = 3
      ),
    )

    let switch1 = createSwitch(service1, maxConnsPerPeer = 0)
    let switch2 = createSwitch(service2, maxConnsPerPeer = 0)

    let awaiter1 = newFuture[void]()

    proc statusAndConfidenceHandler1(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter1.finished:
          awaiter1.complete()

    check service1.networkReachability == NetworkReachability.Unknown

    service1.statusAndConfidenceHandler(statusAndConfidenceHandler1)

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
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 1

    # Make sure remote peer can't create a connection to us
    check switch1.connManager.connCount(switch2.peerInfo.peerId) == 1

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "Must work with low maxConnections":
    let service = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
      config = AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(1.seconds), maxQueueSize = 1
      ),
    )

    let switch1 = createSwitch(service, maxConns = 4)
    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()
    let switch5 = createSwitch()

    var awaiter = newFuture[void]()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      if networkReachability == NetworkReachability.Reachable and confidence.isSome() and
          confidence.get() == 1:
        if not awaiter.finished:
          awaiter.complete()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

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
    await service.run(switch1)

    await sleepAsync(100.millis)

    check service.networkReachability == NetworkReachability.Reachable
    check libp2p_autonat_v2_reachability_confidence.value(["Reachable"]) == 1

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop()
    )

  asyncTest "Peer must not ask an incoming peer":
    let service = AutonatV2Service.new(
      newRng(),
      client = AutonatV2ClientMock.new(
        AutonatV2Response(
          reachability: Reachable,
          dialResp: DialResponse(
            status: ResponseStatus.Ok,
            dialStatus: Opt.some(DialStatus.Ok),
            addrIdx: Opt.some(0.AddrIdx),
          ),
        ),
        expectedDials = 0,
      ),
    )

    let switch1 = createSwitch(service)
    let switch2 = createSwitch()

    proc statusAndConfidenceHandler(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      fail()

    check service.networkReachability == NetworkReachability.Unknown

    service.statusAndConfidenceHandler(statusAndConfidenceHandler)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    await sleepAsync(250.milliseconds)

    await allFuturesThrowing(switch1.stop(), switch2.stop())
