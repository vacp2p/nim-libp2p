{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options, sequtils
import chronos
import stew/byteutils
import
  ../libp2p/[
    errors,
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
    stream/chronosstream,
    utils/semaphore,
    transports/tcptransport,
    transports/wstransport,
    transports/quictransport,
  ]
import ./helpers

const TestCodec = "/test/proto/1.0.0"

type TestProto = ref object of LPProtocol

suite "Switch":
  teardown:
    checkTrackers()

  asyncTest "e2e use switch dial proto string":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
      finally:
        await conn.close()
        done.complete()

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

    await allFuturesThrowing(done.wait(5.seconds), switch1.stop(), switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e use switch dial proto string with custom matcher":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
      finally:
        await conn.close()
        done.complete()

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

    await allFuturesThrowing(done.wait(5.seconds), switch1.stop(), switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e should not leak bufferstreams and connections on channel close":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
      finally:
        await conn.close()
        done.complete()

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

    await allFuturesThrowing(done.wait(5.seconds), switch1.stop(), switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e use connect then dial":
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
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
      secureManagers = [SecureProtocol.Noise], nameResolver = resolver
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
    expect(CatchableError):
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
        switch1.connManager.inSema.count, switch1.connManager.outSema.count,
        switch2.connManager.inSema.count, switch2.connManager.outSema.count,
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
          switch1.connManager.inSema.count, switch1.connManager.outSema.count,
          switch2.connManager.inSema.count, switch2.connManager.outSema.count,
        ]

    await allFuturesThrowing(switch1.stop(), switch2.stop())

  asyncTest "e2e should trigger connection events (remote)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerId, event: ConnEvent) {.async.} =
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
        check false

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
    proc hook(peerId: PeerId, event: ConnEvent) {.async.} =
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
        check false

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
    proc handler(peerId: PeerId, event: PeerEvent) {.async.} =
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
        check false

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
    proc handler(peerId: PeerId, event: PeerEvent) {.async.} =
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
        check false

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

    let rng = crypto.newRng()
    # use same private keys to emulate two connection from same peer
    let privKey = PrivateKey.random(rng[]).tryGet()
    let switch2 = newStandardSwitch(privKey = some(privKey), rng = rng)

    let switch3 = newStandardSwitch(privKey = some(privKey), rng = rng)

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerId, event: PeerEvent) {.async.} =
      kinds = kinds + {event.kind}
      case step
      of 0:
        check:
          event.kind == PeerEventKind.Joined
      of 1:
        check:
          event.kind == PeerEventKind.Left
      else:
        check false # should not trigger this

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
    let rng = crypto.newRng()
    # use same private keys to emulate two connection from same peer
    let
      privateKey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.new(privateKey)

    var switches: seq[Switch]
    var done = newFuture[void]()
    var onConnect: Future[void]
    proc hook(peerId: PeerId, event: ConnEvent) {.async.} =
      case event.kind
      of ConnEventKind.Connected:
        await onConnect
        await switches[0].disconnect(peerInfo.peerId) # trigger disconnect
      of ConnEventKind.Disconnected:
        check not switches[0].isConnected(peerInfo.peerId)
        done.complete()

    switches.add(newStandardSwitch(rng = rng))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    await switches[0].start()

    switches.add(newStandardSwitch(privKey = some(privateKey), rng = rng))
    onConnect =
      switches[1].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)
    await onConnect

    await done

    await allFuturesThrowing(switches.mapIt(it.stop()))

  asyncTest "e2e should allow dropping multiple connections for peer from connection events":
    let rng = crypto.newRng()
    # use same private keys to emulate two connection from same peer
    let
      privateKey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.new(privateKey)

    var conns = 1
    var switches: seq[Switch]
    var done = newFuture[void]()
    var onConnect: Future[void]
    proc hook(peerId2: PeerId, event: ConnEvent) {.async.} =
      case event.kind
      of ConnEventKind.Connected:
        if conns == 5:
          await onConnect
          await switches[0].disconnect(peerInfo.peerId) # trigger disconnect
          return

        conns.inc
      of ConnEventKind.Disconnected:
        if conns == 1:
          check not switches[0].isConnected(peerInfo.peerId)
          done.complete()
        conns.dec

    switches.add(newStandardSwitch(maxConnsPerPeer = 10, rng = rng))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    await switches[0].start()

    for i in 1 .. 5:
      switches.add(newStandardSwitch(privKey = some(privateKey), rng = rng))
      switches[i].addConnEventHandler(hook, ConnEventKind.Disconnected)
      onConnect =
        switches[i].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)
      await onConnect

    await done
    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(switches.mapIt(it.stop()))

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
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        discard await conn.readLp(100)
      except CatchableError:
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

    await allFuturesThrowing(allFutures(switches.mapIt(it.stop())))

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

    expect TooManyConnectionsError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(allFutures(switches.mapIt(it.stop())))

  asyncTest "e2e max incoming connection limits":
    var switches: seq[Switch]
    let destSwitch = newStandardSwitch(maxIn = 3)
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

    await allFuturesThrowing(allFutures(switches.mapIt(it.stop())))

  asyncTest "e2e max outgoing connection limits":
    var switches: seq[Switch]
    for i in 0 ..< 3:
      switches.add(newStandardSwitch())
      await switches[i].start()

    let srcSwitch = newStandardSwitch(maxOut = 3)
    await srcSwitch.start()

    let dstSwitch = newStandardSwitch()
    await dstSwitch.start()

    for s in switches:
      check await srcSwitch.connect(s.peerInfo.peerId, s.peerInfo.addrs).withTimeout(
        1000.millis
      )

    expect TooManyConnectionsError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(allFutures(switches.mapIt(it.stop())))

  asyncTest "e2e peer store":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
      finally:
        await conn.close()
        done.complete()

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

    await allFuturesThrowing(done.wait(5.seconds), switch1.stop(), switch2.stop())

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
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      except:
        check false # should not be here
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
      srcSwitch = newStandardSwitch(nameResolver = resolver)
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

      srcTcpSwitch = newStandardSwitch(nameResolver = resolver)
      srcWsSwitch = SwitchBuilder
        .new()
        .withAddress(wsAddress)
        .withRng(crypto.newRng())
        .withMplex()
        .withTransport(
          proc(upgr: Upgrade): Transport =
            WsTransport.new(upgr)
        )
        .withNameResolver(resolver)
        .withNoise()
        .build()

      destSwitch = SwitchBuilder
        .new()
        .withAddresses(@[tcpAddress, wsAddress])
        .withRng(crypto.newRng())
        .withMplex()
        .withTransport(
          proc(upgr: Upgrade): Transport =
            WsTransport.new(upgr)
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
        .withRng(crypto.newRng())
        .withTransport(
          proc(upgr: Upgrade): Transport =
            QuicTransport.new(upgr)
        )
        .withNoise()
        .build()

      destSwitch = SwitchBuilder
        .new()
        .withAddress(quicAddress2)
        .withRng(crypto.newRng())
        .withTransport(
          proc(upgr: Upgrade): Transport =
            QuicTransport.new(upgr)
        )
        .withNoise()
        .build()

    await destSwitch.start()
    await srcSwitch.start()

    await srcSwitch.connect(destSwitch.peerInfo.peerId, destSwitch.peerInfo.addrs)
    check srcSwitch.isConnected(destSwitch.peerInfo.peerId)

    await destSwitch.stop()
    await srcSwitch.stop()

  asyncTest "mount unstarted protocol":
    proc handle(conn: Connection, proto: string) {.async: (raises: []).} =
      try:
        check "test123" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test456")
      except:
        check false # should not be here
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
