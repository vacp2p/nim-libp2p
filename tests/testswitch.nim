{.used.}

import unittest, options, sequtils
import chronos
import stew/byteutils
import nimcrypto/sysrand
import ../libp2p/[errors,
                  switch,
                  multistream,
                  standard_setup,
                  stream/bufferstream,
                  stream/connection,
                  multiaddress,
                  peerinfo,
                  crypto/crypto,
                  protocols/protocol,
                  protocols/secure/secure,
                  muxers/muxer,
                  muxers/mplex/lpchannel,
                  stream/lpstream]
import ./helpers

const
  TestCodec = "/test/proto/1.0.0"

type
  TestProto = ref object of LPProtocol

suite "Switch":
  teardown:
    checkTrackers()

  asyncTest "e2e use switch dial proto string":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      finally:
        await conn.close()
        done.complete()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    var awaiters: seq[Future[void]]
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    let conn = await switch2.dial(switch1.peerInfo, TestCodec)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop())

    # this needs to go at end
    await allFuturesThrowing(awaiters)

    check not switch1.isConnected(switch2.peerInfo)
    check not switch2.isConnected(switch1.peerInfo)

  asyncTest "e2e use switch dial proto string with custom matcher":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
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
    var awaiters: seq[Future[void]]
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    let conn = await switch2.dial(switch1.peerInfo, callProto)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop())

    # this needs to go at end
    await allFuturesThrowing(awaiters)

    check not switch1.isConnected(switch2.peerInfo)
    check not switch2.isConnected(switch1.peerInfo)

  asyncTest "e2e should not leak bufferstreams and connections on channel close":
    let done = newFuture[void]()
    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      finally:
        await conn.close()
        done.complete()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    var awaiters: seq[Future[void]]
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    let conn = await switch2.dial(switch1.peerInfo, TestCodec)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop(),
    )

    # this needs to go at end
    await allFuturesThrowing(awaiters)

    check not switch1.isConnected(switch2.peerInfo)
    check not switch2.isConnected(switch1.peerInfo)

  asyncTest "e2e use connect then dial":
    var awaiters: seq[Future[void]]

    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
      finally:
        await conn.writeLp("Hello!")
        await conn.close()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)
    let conn = await switch2.dial(switch1.peerInfo, TestCodec)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg

    await allFuturesThrowing(
      conn.close(),
      switch1.stop(),
      switch2.stop()
    )
    await allFuturesThrowing(awaiters)

    check not switch1.isConnected(switch2.peerInfo)
    check not switch2.isConnected(switch1.peerInfo)


  asyncTest "e2e should not leak on peer disconnect":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo)

    check not switch2.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should trigger connection events (remote)":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
      kinds = kinds + {event.kind}
      case step:
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

    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo)

    check not switch2.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {
        ConnEventKind.Connected,
        ConnEventKind.Disconnected
      }

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should trigger connection events (local)":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
      kinds = kinds + {event.kind}
      case step:
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

    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo)

    check not switch2.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {
        ConnEventKind.Connected,
        ConnEventKind.Disconnected
      }

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should trigger peer events (remote)":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerID, event: PeerEvent) {.async, gcsafe.} =
      kinds = kinds + {event.kind}
      case step:
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

    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo)

    check not switch2.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {
        PeerEventKind.Joined,
        PeerEventKind.Left
      }

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should trigger peer events (local)":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerID, event: PeerEvent) {.async, gcsafe.} =
      kinds = kinds + {event.kind}
      case step:
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

    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    await switch2.connect(switch1.peerInfo)

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo)

    check not switch2.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {
        PeerEventKind.Joined,
        PeerEventKind.Left
      }

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should trigger peer events only once per peer":
    var awaiters: seq[Future[void]]

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

    let rng = newRng()
    # use same private keys to emulate two connection from same peer
    let privKey = PrivateKey.random(rng[]).tryGet()
    let switch2 = newStandardSwitch(
      privKey = some(privKey),
      rng = rng,
      secureManagers = [SecureProtocol.Secio])

    let switch3 = newStandardSwitch(
      privKey = some(privKey),
      rng = rng,
      secureManagers = [SecureProtocol.Secio])

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerID, event: PeerEvent) {.async, gcsafe.} =
      kinds = kinds + {event.kind}
      case step:
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

    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())
    awaiters.add(await switch3.start())

    await switch2.connect(switch1.peerInfo) # should trigger 1st Join event
    await switch3.connect(switch1.peerInfo) # should trigger 2nd Join event

    check switch1.isConnected(switch2.peerInfo)
    check switch2.isConnected(switch1.peerInfo)
    check switch3.isConnected(switch1.peerInfo)

    await switch2.disconnect(switch1.peerInfo) # should trigger 1st Left event
    await switch3.disconnect(switch1.peerInfo) # should trigger 2nd Left event

    check not switch2.isConnected(switch1.peerInfo)
    check not switch3.isConnected(switch1.peerInfo)
    await sleepAsync(1.millis)
    check not switch1.isConnected(switch2.peerInfo)

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    check:
      kinds == {
        PeerEventKind.Joined,
        PeerEventKind.Left
      }

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop(),
      switch3.stop())
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should allow dropping peer from connection events":
    var awaiters: seq[Future[void]]

    let rng = newRng()
    # use same private keys to emulate two connection from same peer
    let peerInfo = PeerInfo.init(PrivateKey.random(rng[]).tryGet())

    var switches: seq[Switch]
    var done = newFuture[void]()
    var onConnect: Future[void]
    proc hook(peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
      case event.kind:
      of ConnEventKind.Connected:
        await onConnect
        await switches[0].disconnect(peerInfo.peerId) # trigger disconnect
      of ConnEventKind.Disconnected:
        check not switches[0].isConnected(peerInfo.peerId)
        await sleepAsync(1.millis)
        done.complete()

    switches.add(newStandardSwitch(
        rng = rng,
        secureManagers = [SecureProtocol.Secio]))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    awaiters.add(await switches[0].start())

    switches.add(newStandardSwitch(
      privKey = some(peerInfo.privateKey),
      rng = rng,
      secureManagers = [SecureProtocol.Secio]))
    onConnect = switches[1].connect(switches[0].peerInfo)
    await onConnect

    await done
    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switches.mapIt( it.stop() ))
    await allFuturesThrowing(awaiters)

  asyncTest "e2e should allow dropping multiple connections for peer from connection events":
    var awaiters: seq[Future[void]]

    let rng = newRng()
    # use same private keys to emulate two connection from same peer
    let peerInfo = PeerInfo.init(PrivateKey.random(rng[]).tryGet())

    var conns = 1
    var switches: seq[Switch]
    var done = newFuture[void]()
    var onConnect: Future[void]
    proc hook(peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
      case event.kind:
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

    switches.add(newStandardSwitch(
        rng = rng,
        secureManagers = [SecureProtocol.Secio]))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    awaiters.add(await switches[0].start())

    for i in 1..5:
      switches.add(newStandardSwitch(
        privKey = some(peerInfo.privateKey),
        rng = rng,
        secureManagers = [SecureProtocol.Secio]))
      onConnect = switches[i].connect(switches[0].peerInfo)
      await onConnect

    await done
    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switches.mapIt( it.stop() ))
    await allFuturesThrowing(awaiters)

  asyncTest "connect to inexistent peer":
    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    let sfut = await switch2.start()
    let someAddr = MultiAddress.init("/ip4/127.128.0.99").get()
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    let somePeer = PeerInfo.init(secKey, [someAddr])
    expect(DialFailedError):
      let conn = await switch2.dial(somePeer, TestCodec)
    await switch2.stop()
