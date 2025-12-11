# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import results, sequtils, chronos, stew/byteutils
import
  ../../libp2p/[
    errors,
    dial,
    switch,
    multistream,
    builders,
    stream/bufferstream,
    stream/connection,
    multicodec,
    multiaddress,
    peerinfo,
    crypto/crypto,
    protocols/protocol,
    protocols/secure/secure,
    muxers/muxer,
    muxers/mplex/lpchannel,
    stream/lpstream,
    nameresolving/mockresolver,
    nameresolving/nameresolver,
    stream/chronosstream,
    transports/tcptransport,
    transports/wstransport,
    transports/quictransport,
  ]
import ../tools/[unittest, trackers, futures, crypto, sync]

const TestCodec = "/test/proto/1.0.0"

type TestProto = ref object of LPProtocol

suite "Switch":
  teardown:
    checkTrackers()

  asyncTest "e2e use switch dial proto string":
    let handleFinished = newWaitGroup(1)
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in protocol handler"
      finally:
        await conn.close()
        handleFinished.done()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      handleFinished.wait(5.seconds), switch1.stop(), switch2.stop()
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e use switch dial proto string with custom matcher":
    let handleFinished = newWaitGroup(1)
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in custom matcher protocol handler"
      finally:
        await conn.close()
        handleFinished.done()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let callProto = TestCodec & "/pew"

    proc match(proto: string): bool {.gcsafe.} =
      return proto == callProto

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto, match)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    await switch1.start()
    await switch2.start()

    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, callProto)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      handleFinished.wait(5.seconds), switch1.stop(), switch2.stop()
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e should not leak bufferstreams and connections on channel close":
    let handleFinished = newWaitGroup(1)
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in bufferstream leak test handler"
      finally:
        await conn.close()
        handleFinished.done()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      handleFinished.wait(5.seconds), switch1.stop(), switch2.stop()
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e use connect then dial":
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in connect-then-dial test handler"
      finally:
        await conn.close()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg

    await allFuturesThrowing(conn.close(), switch1.stop(), switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e connect to peer with unknown PeerId":
    let resolver = MockResolver.new()
    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    let switch2 = newStandardSwitch(
      secureManagers = [SecureProtocol.Noise],
      nameResolver = Opt.some(NameResolver(resolver)),
    )
    await switch1.start()
    await switch2.start()

    # via dnsaddr
    resolver.txtResponses["_dnsaddr.test.io"] =
      @["dnsaddr=" & $switch1.peerInfo.addrs[0] & "/p2p/" & $switch1.peerInfo.peerId]

    check:
      (await switch2.connect(MultiAddress.init("/dnsaddr/test.io/").tryGet(), true)) ==
        switch1.peerInfo.peerId
    await switch2.disconnect(switch1.peerInfo.peerId)

    # via direct ip
    check not switch2.isConnected(switch1.peerInfo.peerId)
    check:
      (await switch2.connect(switch1.peerInfo.addrs[0], true)) == switch1.peerInfo.peerId

    await switch2.disconnect(switch1.peerInfo.peerId)

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e connect to peer with known PeerId":
    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    await switch1.start()
    await switch2.start()

    # via direct ip
    check not switch2.isConnected(switch1.peerInfo.peerId)

    # without specifying allow unknown, will fail
    expect(DialFailedError):
      discard await switch2.connect(switch1.peerInfo.addrs[0])

    # with invalid PeerId, will fail
    let fakeMa = concat(
        switch1.peerInfo.addrs[0],
        MultiAddress.init(multiCodec("p2p"), PeerId.random.tryGet().data).tryGet(),
      )
      .tryGet()
    expect(DialFailedError):
      discard (await switch2.connect(fakeMa))

    # real thing works
    check (await switch2.connect(switch1.peerInfo.fullAddrs.tryGet()[0])) ==
      switch1.peerInfo.peerId

    await switch2.disconnect(switch1.peerInfo.peerId)

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should not leak on peer disconnect":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let startCounts =
      @[
        switch1.connManager.inSema.availableSlots,
        switch1.connManager.outSema.availableSlots,
        switch2.connManager.inSema.availableSlots,
        switch2.connManager.outSema.availableSlots,
      ]

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    checkUntilTimeout:
      startCounts ==
        @[
          switch1.connManager.inSema.availableSlots,
          switch1.connManager.outSema.availableSlots,
          switch2.connManager.inSema.availableSlots,
          switch2.connManager.outSema.availableSlots,
        ]

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger connection events (remote)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerId, event: ConnEvent) {.async: (raises: [CancelledError]).} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == ConnEventKind.Connected
          peerId == switch1.peerInfo.peerId
      of 1:
        check:
          event.kind == ConnEventKind.Disconnected

        check peerId == switch1.peerInfo.peerId
      else:
        raiseAssert "Connection event hook called more than expected"

      step.inc()

    switch2.addConnEventHandler(hook, ConnEventKind.Connected)
    switch2.addConnEventHandler(hook, ConnEventKind.Disconnected)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {ConnEventKind.Connected, ConnEventKind.Disconnected}

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger connection events (local)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerId, event: ConnEvent) {.async: (raises: [CancelledError]).} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == ConnEventKind.Connected
          peerId == switch2.peerInfo.peerId
      of 1:
        check:
          event.kind == ConnEventKind.Disconnected

        check peerId == switch2.peerInfo.peerId
      else:
        raiseAssert "Connection event hook called more than expected"

      step.inc()

    switch1.addConnEventHandler(hook, ConnEventKind.Connected)
    switch1.addConnEventHandler(hook, ConnEventKind.Disconnected)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {ConnEventKind.Connected, ConnEventKind.Disconnected}

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger peer events (remote)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(
        peerId: PeerId, event: PeerEvent
    ) {.async: (raises: [CancelledError]).} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == PeerEventKind.Joined
          peerId == switch2.peerInfo.peerId
      of 1:
        check:
          event.kind == PeerEventKind.Left
          peerId == switch2.peerInfo.peerId
      else:
        raiseAssert "Peer event handler called more than expected"

      step.inc()

    switch1.addPeerEventHandler(handler, PeerEventKind.Joined)
    switch1.addPeerEventHandler(handler, PeerEventKind.Left)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {PeerEventKind.Joined, PeerEventKind.Left}

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger peer events (local)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(
        peerId: PeerId, event: PeerEvent
    ) {.async: (raises: [CancelledError]).} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == PeerEventKind.Joined
          peerId == switch1.peerInfo.peerId
      of 1:
        check:
          event.kind == PeerEventKind.Left
          peerId == switch1.peerInfo.peerId
      else:
        raiseAssert "Peer event handler called more than expected"

      step.inc()

    switch2.addPeerEventHandler(handler, PeerEventKind.Joined)
    switch2.addPeerEventHandler(handler, PeerEventKind.Left)

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {PeerEventKind.Joined, PeerEventKind.Left}

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger peer events only once per peer":
    let switch1 = newStandardSwitch()

    # use same private keys to emulate two connection from same peer
    let privKey = PrivateKey.random(rng[]).tryGet()
    let switch2 = newStandardSwitch(privKey = Opt.some(privKey), rng = rng)

    let switch3 = newStandardSwitch(privKey = Opt.some(privKey), rng = rng)

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(
        peerId: PeerId, event: PeerEvent
    ) {.async: (raises: [CancelledError]).} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == PeerEventKind.Joined
      of 1:
        check:
          event.kind == PeerEventKind.Left
      else:
        raiseAssert "Peer event handler called more than expected"

      step.inc()

    switch1.addPeerEventHandler(handler, PeerEventKind.Joined)
    switch1.addPeerEventHandler(handler, PeerEventKind.Left)

    await switch1.start()
    await switch2.start()
    await switch3.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
      # should trigger 1st Join event
    await switch3.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
      # should trigger 2nd Join event

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)
    check switch3.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId) # should trigger 1st Left event
    await switch3.disconnect(switch1.peerInfo.peerId) # should trigger 2nd Left event

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check not switch3.isConnected(switch1.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)
    checkUntilTimeout:
      not switch1.isConnected(switch3.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {PeerEventKind.Joined, PeerEventKind.Left}

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop())

  asyncTest "e2e should allow dropping peer from connection events":
    # use same private keys to emulate two connection from same peer
    let
      privateKey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.new(privateKey)

    var switches: seq[Switch]
    let onDisconnect = newWaitGroup(1)
    let onConnect = newWaitGroup(1)

    proc hook(peerId: PeerId, event: ConnEvent) {.async: (raises: [CancelledError]).} =
      try:
        case event.kind
        of ConnEventKind.Connected:
          await onConnect.wait()
          await switches[0].disconnect(peerInfo.peerId) # trigger disconnect
        of ConnEventKind.Disconnected:
          check not switches[0].isConnected(peerInfo.peerId)
          onDisconnect.done()
      except DialFailedError:
        raiseAssert "Unexpected DialFailedError in connection event hook"

    switches.add(newStandardSwitch(rng = rng))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    await switches[0].start()

    switches.add(newStandardSwitch(privKey = Opt.some(privateKey), rng = rng))
    await switches[1].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)
    onConnect.done()

    await onDisconnect.wait()

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e should allow dropping multiple connections for peer from connection events":
    let privateKey = PrivateKey.random(rng[]).tryGet()
    let peerInfo = PeerInfo.new(privateKey)

    var conns = 0
    var switches: seq[Switch]
    let allDisconnected = newWaitGroup(5)
    let allConnected = newWaitGroup(5)

    proc hook(_: PeerId, event: ConnEvent) {.async: (raises: [CancelledError]).} =
      case event.kind
      of ConnEventKind.Connected:
        allConnected.done()
      of ConnEventKind.Disconnected:
        allDisconnected.done()

    # Start first switch
    switches.add(newStandardSwitch(maxConnsPerPeer = 10, rng = rng))
    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    await switches[0].start()

    # Connect remaining switches sequentially
    for i in 1 .. 5:
      switches.add(newStandardSwitch(privKey = Opt.some(privateKey), rng = rng))
      switches[i].addConnEventHandler(hook, ConnEventKind.Connected)
      switches[i].addConnEventHandler(hook, ConnEventKind.Disconnected)
      await switches[i].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)

    # Wait until all 5 are connected
    await allConnected.wait(5.seconds)

    # Trigger disconnect safely
    await switches[0].disconnect(peerInfo.peerId)

    # Wait until all disconnected
    await allDisconnected.wait(5.seconds)
    check not switches[0].isConnected(peerInfo.peerId)

    checkUntilTimeout:
      not isCounterLeaked(LPChannelTrackerName)
      not isCounterLeaked(SecureConnTrackerName)

    await allFuturesThrowing(switches[0].stop())

  asyncTest "e2e closing remote conn should not leak":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    let transport = TcpTransport.new(upgrade = Upgrade())
    await transport.start(ma)

    proc acceptHandler() {.async.} =
      let conn = await transport.accept()
      await conn.closeWithEOF()

    let handlerWait = acceptHandler()
    let switch = newStandardSwitch(secureManagers = [SecureProtocol.Noise])

    await switch.start()

    var peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).get()
    expect DialFailedError:
      await switch.connect(peerId, transport.addrs)

    await handlerWait

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)
    checkTracker(ChronosStreamTrackerName)

    await allFuturesThrowing(transport.stop(), switch.stop())

  asyncTest "e2e calling closeWithEOF on the same stream should not assert":
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        discard await conn.readLp(100)
      except LPStreamError:
        check true # should be here

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])

    await switch1.start()

    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    proc closeReader() {.async.} =
      await conn.closeWithEOF()

    var readers: seq[Future[void]]
    for i in 0 .. 10:
      readers.add(closeReader())

    await allFuturesThrowing(readers)
    await switch2.stop() #Otherwise this leaks
    checkUntilTimeout:
      not switch1.isConnected(switch2.peerInfo.peerId)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)
    checkTracker(ChronosStreamTrackerName)

    await switch1.stop()

  asyncTest "connect to inexistent peer":
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    await switch2.start()
    let someAddr = MultiAddress.init("/ip4/127.128.0.99").get()
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    let somePeer = PeerInfo.new(seckey, [someAddr])
    expect(DialFailedError):
      discard await switch2.dial(somePeer.peerId, somePeer.addrs, TestCodec)
    await switch2.stop()

  asyncTest "e2e total connection limits on incoming connections":
    var switches: seq[Switch]
    let destSwitch = newStandardSwitch(maxConnections = 3)
    switches.add(destSwitch)
    await destSwitch.start()

    let destPeerInfo = destSwitch.peerInfo
    for i in 0 ..< 3:
      let switch = newStandardSwitch()
      switches.add(switch)
      await switch.start()

      check await switch.connect(destPeerInfo.peerId, destPeerInfo.addrs).withTimeout(
        1000.millis
      )

    let switchFail = newStandardSwitch()
    switches.add(switchFail)
    await switchFail.start()

    check not (
      await switchFail.connect(destPeerInfo.peerId, destPeerInfo.addrs).withTimeout(
        1000.millis
      )
    )

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e total connection limits on incoming connections":
    var switches: seq[Switch]
    for i in 0 ..< 3:
      switches.add(newStandardSwitch())
      await switches[i].start()

    let srcSwitch = newStandardSwitch(maxConnections = 3)
    await srcSwitch.start()

    let dstSwitch = newStandardSwitch()
    await dstSwitch.start()

    for s in switches:
      check await srcSwitch.connect(s.peerInfo.peerId, s.peerInfo.addrs).withTimeout(
        1000.millis
      )

    expect DialFailedError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e max incoming connection limits":
    var switches: seq[Switch]
    let destSwitch = newStandardSwitch(maxIn = 3, maxOut = 1)
    switches.add(destSwitch)
    await destSwitch.start()

    let destPeerInfo = destSwitch.peerInfo
    for i in 0 ..< 3:
      let switch = newStandardSwitch()
      switches.add(switch)
      await switch.start()

      check await switch.connect(destPeerInfo.peerId, destPeerInfo.addrs).withTimeout(
        1000.millis
      )

    let switchFail = newStandardSwitch()
    switches.add(switchFail)
    await switchFail.start()

    check not (
      await switchFail.connect(destPeerInfo.peerId, destPeerInfo.addrs).withTimeout(
        1000.millis
      )
    )

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e max outgoing connection limits":
    var switches: seq[Switch]
    for i in 0 ..< 3:
      switches.add(newStandardSwitch())
      await switches[i].start()

    let srcSwitch = newStandardSwitch(maxOut = 3, maxIn = 1)
    await srcSwitch.start()

    let dstSwitch = newStandardSwitch()
    await dstSwitch.start()

    for s in switches:
      check await srcSwitch.connect(s.peerInfo.peerId, s.peerInfo.addrs).withTimeout(
        1000.millis
      )

    expect DialFailedError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e peer store":
    let handleFinished = newWaitGroup(1)
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in peer store test handler"
      finally:
        await conn.close()
        handleFinished.done()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(peerStoreCapacity = 0)
    await switch1.start()
    await switch2.start()

    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      handleFinished.wait(5.seconds), switch1.stop(), switch2.stop()
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

    check:
      switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs
      switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] == switch2.peerInfo.protocols

      switch1.peerStore[LastSeenBook][switch2.peerInfo.peerId].isSome()

      switch1.peerInfo.peerId notin switch2.peerStore[AddressBook]
      switch1.peerInfo.peerId notin switch2.peerStore[ProtoBook]

  asyncTest "e2e should allow multiple local addresses":
    when defined(windows):
      # this randomly locks the Windows CI job
      skip()
      return
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in multiple local addresses test handler"
      finally:
        await conn.close()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let addrs =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
        MultiAddress.init("/ip6/::1/tcp/0").tryGet(),
      ]

    let switch1 = newStandardSwitch(
      addrs = addrs, transportFlags = {ServerFlags.ReuseAddr, ServerFlags.ReusePort}
    )

    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    let switch3 =
      newStandardSwitch(addrs = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())

    await allFuturesThrowing(switch1.start(), switch2.start(), switch3.start())

    check IP4.matchPartial(switch1.peerInfo.addrs[0])
    check IP6.matchPartial(switch1.peerInfo.addrs[1])

    let conn = await switch2.dial(
      switch1.peerInfo.peerId, @[switch1.peerInfo.addrs[0]], TestCodec
    )

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    check "Hello!" == string.fromBytes(await conn.readLp(1024))
    await conn.close()

    let connv6 = await switch3.dial(
      switch1.peerInfo.peerId, @[switch1.peerInfo.addrs[1]], TestCodec
    )

    check switch1.isConnected(switch3.peerInfo.peerId)
    check switch3.isConnected(switch1.peerInfo.peerId)

    await connv6.writeLp("Hello!")
    check "Hello!" == string.fromBytes(await connv6.readLp(1024))
    await connv6.close()

    await allFuturesThrowing(switch1.stop(), switch2.stop(), switch3.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e dial dns4 address":
    let resolver = MockResolver.new()
    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
    resolver.ipResponses[("localhost", true)] = @["::1"]

    let
      srcSwitch = newStandardSwitch(nameResolver = Opt.some(NameResolver(resolver)))
      destSwitch = newStandardSwitch()

    await destSwitch.start()
    await srcSwitch.start()

    let testAddr =
      MultiAddress.init("/dns4/localhost/").tryGet() &
      destSwitch.peerInfo.addrs[0][1].tryGet()

    await srcSwitch.connect(destSwitch.peerInfo.peerId, @[testAddr])
    check srcSwitch.isConnected(destSwitch.peerInfo.peerId)

    await destSwitch.stop()
    await srcSwitch.stop()

  asyncTest "e2e dial dnsaddr with multiple transports":
    let resolver = MockResolver.new()

    let
      wsAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()
      tcpAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()

      srcTcpSwitch = newStandardSwitch(nameResolver = Opt.some(NameResolver(resolver)))
      srcWsSwitch = SwitchBuilder
        .new()
        .withAddress(wsAddress)
        .withRng(rng)
        .withMplex()
        .withTransport(
          proc(config: TransportConfig): Transport =
            WsTransport.new(config.upgr)
        )
        .withNameResolver(resolver)
        .withNoise()
        .build()

      destSwitch = SwitchBuilder
        .new()
        .withAddresses(@[tcpAddress, wsAddress])
        .withRng(rng)
        .withMplex()
        .withTransport(
          proc(config: TransportConfig): Transport =
            WsTransport.new(config.upgr)
        )
        .withTcpTransport()
        .withNoise()
        .build()

    await destSwitch.start()
    await srcWsSwitch.start()

    resolver.txtResponses["_dnsaddr.test.io"] =
      @[
        "dnsaddr=/dns4/localhost" & $destSwitch.peerInfo.addrs[0][1 ..^ 1].tryGet() &
          "/p2p/" & $destSwitch.peerInfo.peerId,
        "dnsaddr=/dns4/localhost" & $destSwitch.peerInfo.addrs[1][1 ..^ 1].tryGet(),
      ]
    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]

    let testAddr = MultiAddress.init("/dnsaddr/test.io/").tryGet()

    await srcTcpSwitch.connect(destSwitch.peerInfo.peerId, @[testAddr])
    check srcTcpSwitch.isConnected(destSwitch.peerInfo.peerId)

    await srcWsSwitch.connect(destSwitch.peerInfo.peerId, @[testAddr])
    check srcWsSwitch.isConnected(destSwitch.peerInfo.peerId)

    await destSwitch.stop()
    await srcWsSwitch.stop()
    await srcTcpSwitch.stop()

  asyncTest "e2e quic transport":
    let
      quicAddress1 = MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()
      quicAddress2 = MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()

      srcSwitch = SwitchBuilder
        .new()
        .withAddress(quicAddress1)
        .withRng(rng)
        .withQuicTransport()
        .withNoise()
        .build()

      destSwitch = SwitchBuilder
        .new()
        .withAddress(quicAddress2)
        .withRng(rng)
        .withQuicTransport()
        .withNoise()
        .build()

    await destSwitch.start()
    await srcSwitch.start()

    await srcSwitch.connect(destSwitch.peerInfo.peerId, destSwitch.peerInfo.addrs)
    check srcSwitch.isConnected(destSwitch.peerInfo.peerId)

    await destSwitch.stop()
    await srcSwitch.stop()

  asyncTest "e2e multiple transports coexistence":
    let
      tcpAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      wsAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()
      quicAddress = MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()

      destSwitch = SwitchBuilder
        .new()
        .withAddresses(@[tcpAddress, wsAddress, quicAddress])
        .withRng(rng)
        .withMplex()
        .withTransport(
          proc(config: TransportConfig): Transport =
            WsTransport.new(config.upgr)
        )
        .withTcpTransport()
        .withQuicTransport()
        .withNoise()
        .build()

      srcTcpSwitch =
        newStandardSwitch(addrs = tcpAddress, transport = TransportType.TCP)
      srcWsSwitch = SwitchBuilder
        .new()
        .withAddress(wsAddress)
        .withRng(rng)
        .withMplex()
        .withTransport(
          proc(config: TransportConfig): Transport =
            WsTransport.new(config.upgr)
        )
        .withNoise()
        .build()
      srcQuicSwitch =
        newStandardSwitch(addrs = quicAddress, transport = TransportType.QUIC)

    let switches = @[destSwitch, srcTcpSwitch, srcWsSwitch, srcQuicSwitch]
    await allFutures(switches.mapIt(it.start()))
    defer:
      await allFutures(switches.mapIt(it.stop()))

    # Verify all three transport types are available in destSwitch
    check destSwitch.peerInfo.addrs.len == 3

    # Test TCP transport connection
    await srcTcpSwitch.connect(
      destSwitch.peerInfo.peerId, @[destSwitch.peerInfo.addrs[0]]
    )
    check srcTcpSwitch.isConnected(destSwitch.peerInfo.peerId)

    # Test WebSocket transport connection
    await srcWsSwitch.connect(
      destSwitch.peerInfo.peerId, @[destSwitch.peerInfo.addrs[1]]
    )
    check srcWsSwitch.isConnected(destSwitch.peerInfo.peerId)

    # Test QUIC transport connection
    await srcQuicSwitch.connect(
      destSwitch.peerInfo.peerId, @[destSwitch.peerInfo.addrs[2]]
    )
    check srcQuicSwitch.isConnected(destSwitch.peerInfo.peerId)

  asyncTest "mount unstarted protocol":
    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        check "test123" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test456")
      except LPStreamError:
        raiseAssert "Unexpected LPStreamError in mount unstarted protocol test handler"
      finally:
        await conn.close()

    let
      src = newStandardSwitch()
      dst = newStandardSwitch()
      testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    await src.start()
    await dst.start()
    expect LPError:
      dst.mount(testProto)
    await testProto.start()
    dst.mount(testProto)

    let conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, TestCodec)
    await conn.writeLp("test123")
    check "test456" == string.fromBytes(await conn.readLp(1024))
    await conn.close()
    await src.stop()
    await dst.stop()

  asyncTest "switch failing to start stops properly":
    let switch = newStandardSwitch(
      addrs =
        @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
          MultiAddress.init("/ip4/1.1.1.1/tcp/0").tryGet(),
        ]
    )

    expect LPError:
      await switch.start()
    # test is that this doesn't leak

  asyncTest "starting two times does not crash":
    let switch =
      newStandardSwitch(addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])

    await switch.start()
    await switch.start()

    await allFuturesThrowing(switch.stop())
