{.used.}

import options, sequtils, sets, sugar, tables
import chronos
import stew/byteutils
import nimcrypto/sysrand
import ../libp2p/[errors,
                  switch,
                  multistream,
                  builders,
                  stream/bufferstream,
                  stream/connection,
                  multiaddress,
                  peerinfo,
                  crypto/crypto,
                  protocols/protocol,
                  protocols/secure/secure,
                  muxers/muxer,
                  muxers/mplex/lpchannel,
                  muxers/mplex/mplex,
                  stream/lpstream,
                  nameresolving/nameresolver,
                  nameresolving/mockresolver,
                  stream/chronosstream,
                  transports/tcptransport,
                  transports/wstransport]
import ./mocks/mocktransport
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

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

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
    await switch1.start()
    await switch2.start()

    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, callProto)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

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

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop(),
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e use connect then dial":
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
    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg

    await allFuturesThrowing(
      conn.close(),
      switch1.stop(),
      switch2.stop()
    )

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

  asyncTest "e2e should not leak on peer disconnect":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())

  asyncTest "e2e should trigger connection events (remote)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerId, event: ConnEvent) {.async, gcsafe.} =
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

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))

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

  asyncTest "e2e should trigger connection events (local)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[ConnEventKind]
    proc hook(peerId: PeerId, event: ConnEvent) {.async, gcsafe.} =
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

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))

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

  asyncTest "e2e should trigger peer events (remote)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerId, event: PeerEvent) {.async, gcsafe.} =
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

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))

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

  asyncTest "e2e should trigger peer events (local)":
    let switch1 = newStandardSwitch()
    let switch2 = newStandardSwitch()

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerId, event: PeerEvent) {.async, gcsafe.} =
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

    await switch1.start()
    await switch2.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId)

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))

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

  asyncTest "e2e should trigger peer events only once per peer":
    let switch1 = newStandardSwitch()

    let rng = crypto.newRng()
    # use same private keys to emulate two connection from same peer
    let privKey = PrivateKey.random(rng[]).tryGet()
    let switch2 = newStandardSwitch(
      privKey = some(privKey),
      rng = rng)

    let switch3 = newStandardSwitch(
      privKey = some(privKey),
      rng = rng)

    var step = 0
    var kinds: set[PeerEventKind]
    proc handler(peerId: PeerId, event: PeerEvent) {.async, gcsafe.} =
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

    await switch1.start()
    await switch2.start()
    await switch3.start()

    await switch2.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs) # should trigger 1st Join event
    await switch3.connect(switch1.peerInfo.peerId, switch1.peerInfo.addrs) # should trigger 2nd Join event

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)
    check switch3.isConnected(switch1.peerInfo.peerId)

    await switch2.disconnect(switch1.peerInfo.peerId) # should trigger 1st Left event
    await switch3.disconnect(switch1.peerInfo.peerId) # should trigger 2nd Left event

    check not switch2.isConnected(switch1.peerInfo.peerId)
    check not switch3.isConnected(switch1.peerInfo.peerId)
    check await(checkExpiring((not switch1.isConnected(switch2.peerInfo.peerId))))
    check await(checkExpiring((not switch1.isConnected(switch3.peerInfo.peerId))))

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

  asyncTest "e2e should allow dropping peer from connection events":
    let rng = crypto.newRng()
    # use same private keys to emulate two connection from same peer
    let
      privateKey = PrivateKey.random(rng[]).tryGet()
      peerInfo = PeerInfo.new(privateKey)

    var switches: seq[Switch]
    var done = newFuture[void]()
    var onConnect: Future[void]
    proc hook(peerId: PeerId, event: ConnEvent) {.async, gcsafe.} =
      case event.kind:
      of ConnEventKind.Connected:
        await onConnect
        await switches[0].disconnect(peerInfo.peerId) # trigger disconnect
      of ConnEventKind.Disconnected:
        check not switches[0].isConnected(peerInfo.peerId)
        await sleepAsync(1.millis)
        done.complete()

    switches.add(newStandardSwitch(
        rng = rng))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    switches[0].addConnEventHandler(hook, ConnEventKind.Disconnected)
    await switches[0].start()

    switches.add(newStandardSwitch(
      privKey = some(privateKey),
      rng = rng))
    onConnect = switches[1].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)
    await onConnect

    await done
    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switches.mapIt( it.stop() ))

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
    proc hook(peerId2: PeerId, event: ConnEvent) {.async, gcsafe.} =
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
        rng = rng))

    switches[0].addConnEventHandler(hook, ConnEventKind.Connected)
    await switches[0].start()

    for i in 1..5:
      switches.add(newStandardSwitch(
        privKey = some(privateKey),
        rng = rng))
      switches[i].addConnEventHandler(hook, ConnEventKind.Disconnected)
      onConnect = switches[i].connect(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)
      await onConnect

    await done
    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)

    await allFuturesThrowing(
      switches.mapIt( it.stop() ))

  # TODO: we should be able to test cancellation
  # for most of the steps in the upgrade flow -
  # this is just a basic test for dials
  asyncTest "e2e canceling dial should not leak":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    let transport = TcpTransport.new(upgrade = Upgrade())
    await transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      try:
        let conn = await transport.accept()
        discard await conn.readLp(100)
        await conn.close()
      except CatchableError:
        discard

    let handlerWait = acceptHandler()
    let switch = newStandardSwitch(secureManagers = [SecureProtocol.Noise])

    await switch.start()

    var peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).get()
    let connectFut = switch.connect(peerId, transport.addrs)
    await sleepAsync(500.millis)
    connectFut.cancel()
    await handlerWait

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)
    checkTracker(ChronosStreamTrackerName)

    await allFuturesThrowing(
      transport.stop(),
      switch.stop())

  asyncTest "e2e closing remote conn should not leak":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    let transport = TcpTransport.new(upgrade = Upgrade())
    await transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport.accept()
      await conn.closeWithEOF()

    let handlerWait = acceptHandler()
    let switch = newStandardSwitch(secureManagers = [SecureProtocol.Noise])

    await switch.start()

    var peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).get()
    expect LPStreamClosedError, LPStreamEOFError:
      await switch.connect(peerId, transport.addrs)

    await handlerWait

    checkTracker(LPChannelTrackerName)
    checkTracker(SecureConnTrackerName)
    checkTracker(ChronosStreamTrackerName)

    await allFuturesThrowing(
      transport.stop(),
      switch.stop())

  asyncTest "e2e calling closeWithEOF on the same stream should not assert":
    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      discard await conn.readLp(100)

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])
    switch1.mount(testProto)

    let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Noise])

    await switch1.start()

    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    proc closeReader() {.async.} =
      await conn.closeWithEOF()

    var readers: seq[Future[void]]
    for i in 0..10:
      readers.add(closeReader())

    await allFuturesThrowing(readers)
    await switch2.stop() #Otherwise this leaks
    check await checkExpiring(not switch1.isConnected(switch2.peerInfo.peerId))

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
    for i in 0..<3:
      let switch = newStandardSwitch()
      switches.add(switch)
      await switch.start()

      check await switch.connect(destPeerInfo.peerId, destPeerInfo.addrs)
        .withTimeout(1000.millis)

    let switchFail = newStandardSwitch()
    switches.add(switchFail)
    await switchFail.start()

    check not(await switchFail.connect(destPeerInfo.peerId, destPeerInfo.addrs)
      .withTimeout(1000.millis))

    await allFuturesThrowing(
      allFutures(switches.mapIt( it.stop() )))

  asyncTest "e2e total connection limits on incoming connections":
    var switches: seq[Switch]
    for i in 0..<3:
      switches.add(newStandardSwitch())
      await switches[i].start()

    let srcSwitch = newStandardSwitch(maxConnections = 3)
    await srcSwitch.start()

    let dstSwitch = newStandardSwitch()
    await dstSwitch.start()

    for s in switches:
      check await srcSwitch.connect(s.peerInfo.peerId, s.peerInfo.addrs)
      .withTimeout(1000.millis)

    expect TooManyConnectionsError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(
      allFutures(switches.mapIt( it.stop() )))

  asyncTest "e2e max incoming connection limits":
    var switches: seq[Switch]
    let destSwitch = newStandardSwitch(maxIn = 3)
    switches.add(destSwitch)
    await destSwitch.start()

    let destPeerInfo = destSwitch.peerInfo
    for i in 0..<3:
      let switch = newStandardSwitch()
      switches.add(switch)
      await switch.start()

      check await switch.connect(destPeerInfo.peerId, destPeerInfo.addrs)
        .withTimeout(1000.millis)

    let switchFail = newStandardSwitch()
    switches.add(switchFail)
    await switchFail.start()

    check not(await switchFail.connect(destPeerInfo.peerId, destPeerInfo.addrs)
      .withTimeout(1000.millis))

    await allFuturesThrowing(
      allFutures(switches.mapIt( it.stop() )))

  asyncTest "e2e max outgoing connection limits":

    var switches: seq[Switch]
    for i in 0..<3:
      switches.add(newStandardSwitch())
      await switches[i].start()

    let srcSwitch = newStandardSwitch(maxOut = 3)
    await srcSwitch.start()

    let dstSwitch = newStandardSwitch()
    await dstSwitch.start()

    for s in switches:
      check await srcSwitch.connect(s.peerInfo.peerId, s.peerInfo.addrs)
      .withTimeout(1000.millis)

    expect TooManyConnectionsError:
      await srcSwitch.connect(dstSwitch.peerInfo.peerId, dstSwitch.peerInfo.addrs)

    switches.add(srcSwitch)
    switches.add(dstSwitch)

    await allFuturesThrowing(
      allFutures(switches.mapIt( it.stop() )))

  asyncTest "e2e peer store":
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

    let switch1 = newStandardSwitch()
    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      done.wait(5.seconds),
      switch1.stop(),
      switch2.stop())

    check not switch1.isConnected(switch2.peerInfo.peerId)
    check not switch2.isConnected(switch1.peerInfo.peerId)

    check:
      switch1.peerStore.addressBook.get(switch2.peerInfo.peerId) == switch2.peerInfo.addrs.toHashSet()
      switch2.peerStore.addressBook.get(switch1.peerInfo.peerId) == switch1.peerInfo.addrs.toHashSet()

      switch1.peerStore.protoBook.get(switch2.peerInfo.peerId) == switch2.peerInfo.protocols.toHashSet()
      switch2.peerStore.protoBook.get(switch1.peerInfo.peerId) == switch1.peerInfo.protocols.toHashSet()

  asyncTest "e2e should allow multiple local addresses":
    proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
      try:
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
      finally:
        await conn.close()

    let testProto = new TestProto
    testProto.codec = TestCodec
    testProto.handler = handle

    let addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
                  MultiAddress.init("/ip6/::1/tcp/0").tryGet()]

    let switch1 = newStandardSwitch(
      addrs = addrs,
      transportFlags = {ServerFlags.ReuseAddr, ServerFlags.ReusePort})

    switch1.mount(testProto)

    let switch2 = newStandardSwitch()
    let switch3 = newStandardSwitch(
      addrs = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
    )

    await allFuturesThrowing(
      switch1.start(),
      switch2.start(),
      switch3.start())

    check IP4.matchPartial(switch1.peerInfo.addrs[0])
    check IP6.matchPartial(switch1.peerInfo.addrs[1])

    let conn = await switch2.dial(
      switch1.peerInfo.peerId,
      @[switch1.peerInfo.addrs[0]],
      TestCodec)

    check switch1.isConnected(switch2.peerInfo.peerId)
    check switch2.isConnected(switch1.peerInfo.peerId)

    await conn.writeLp("Hello!")
    check "Hello!" == string.fromBytes(await conn.readLp(1024))
    await conn.close()

    let connv6 = await switch3.dial(
      switch1.peerInfo.peerId,
      @[switch1.peerInfo.addrs[1]],
      TestCodec)

    check switch1.isConnected(switch3.peerInfo.peerId)
    check switch3.isConnected(switch1.peerInfo.peerId)

    await connv6.writeLp("Hello!")
    check "Hello!" == string.fromBytes(await connv6.readLp(1024))
    await connv6.close()

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop(),
      switch3.stop())

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

    let testAddr = MultiAddress.init("/dns4/localhost/").tryGet() &
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
      srcWsSwitch =
        SwitchBuilder.new()
        .withAddress(wsAddress)
        .withRng(crypto.newRng())
        .withMplex()
        .withTransport(proc (upgr: Upgrade): Transport = WsTransport.new(upgr))
        .withNameResolver(resolver)
        .withNoise()
        .build()

      destSwitch =
        SwitchBuilder.new()
        .withAddresses(@[tcpAddress, wsAddress])
        .withRng(crypto.newRng())
        .withMplex()
        .withTransport(proc (upgr: Upgrade): Transport = WsTransport.new(upgr))
        .withTcpTransport()
        .withNoise()
        .build()

    await destSwitch.start()
    await srcWsSwitch.start()

    resolver.txtResponses["_dnsaddr.test.io"] = @[
      "dnsaddr=" & $destSwitch.peerInfo.addrs[0],
      "dnsaddr=" & $destSwitch.peerInfo.addrs[1]
    ]

    let testAddr = MultiAddress.init("/dnsaddr/test.io/").tryGet()

    await srcTcpSwitch.connect(destSwitch.peerInfo.peerId, @[testAddr])
    check srcTcpSwitch.isConnected(destSwitch.peerInfo.peerId)

    await srcWsSwitch.connect(destSwitch.peerInfo.peerId, @[testAddr])
    check srcWsSwitch.isConnected(destSwitch.peerInfo.peerId)

    await destSwitch.stop()
    await srcWsSwitch.stop()
    await srcTcpSwitch.stop()

  asyncTest "pessimistic: transport listenError callback default, should re-raise first address failure":
    let
      exc = buildExceptions(3)

      transportStartMock =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              if i == 0:
                raise exc[0]
              else:
                fail()
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              if not err.isNil:
                raise err
              # return
          fail() # should not get this far

      mockTransport =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport) # Use MockTransport as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    try:
      await switch.start()
      fail()
    except TransportListenError as e:
      check:
        e.ma == mAddrs[0]
        e.parent == exc[0]

    await switch.stop()

  asyncTest "pessimistic: transport listenError callback overridden, should re-raise first failures":
    var handledTransportErrs = initTable[MultiAddress, ref CatchableError]()
    let
      exc = buildExceptions(3)

      transportListenError =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs[ma] = ex
          return newTransportListenError(ma, ex) # optimistic transport multiaddress failure

      transportStartMock =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              raise exc[i]
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              # check err == nil
              if not err.isNil:
                raise err

      mockTransport =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock,
            listenError = transportListenError)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport) # Use MockTransport as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    try:
      await switch.start()
    except TransportListenError as e:
      check e.parent == exc[0]

    echo "handledTransportErrs:"
    for ma, ex in handledTransportErrs:
      echo "ma: ", $ma, ", ex: ", ex.msg

    check handledTransportErrs == [(mAddrs[0], exc[0])].toTable()

    await switch.stop()

  asyncTest "optimistic: transport listenError callback overridden, should not re-raise any failures":
    var handledTransportErrs = initTable[MultiAddress, ref CatchableError]()
    let
      exc = buildExceptions(3)

      transportListenError =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs[ma] = ex
          return nil # optimistic transport multiaddress failure

      transportStartMock =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              raise exc[i]
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              # check err == nil
              if not err.isNil:
                raise err

      mockTransport =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock,
            listenError = transportListenError)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport) # Use MockTransport as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    try:
      await switch.start()
    except TransportListenError:
      fail()

    echo "handledTransportErrs:"
    for mAddr, ex in handledTransportErrs:
      echo "ma: ", $mAddr, ", ex: ", ex.msg

    check handledTransportErrs == [(mAddrs[0], exc[0]), (mAddrs[1], exc[1]), (mAddrs[2], exc[2])].toTable()

    await switch.stop()

  asyncTest "mixed: transport0 optimistic, transport1 pessimistic, transport1.listenError only gets first address exception":
    var
      handledTransportErrs0 = initTable[MultiAddress, ref CatchableError]()
      handledTransportErrs1 = initTable[MultiAddress, ref CatchableError]()

    let
      exc = buildExceptions(2, 3)

      transportListenError0 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs0[ma] = ex
          # optimistic transport multiaddress failure
          return nil

      transportListenError1 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs1[ma] = ex
          # pessimistic transport multiaddress failure
          return newTransportListenError(ma, ex)

      transportStartMock0 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              raise exc[0][i]
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              if not err.isNil:
                raise err

      transportStartMock1 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              if i == 0:
                continue
              elif i == 1:
                raise exc[1][i]
              else:
                fail()
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              if not err.isNil:
                raise err

      mockTransport0 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock0,
            listenError = transportListenError0)
          except: return

      mockTransport1 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock1,
            listenError = transportListenError1)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport0) # Use MockTransport 0 as transport
        .withTransport(mockTransport1) # Use MockTransport 1 as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    var listenErrCalled = false

    try:
      await switch.start()
    except TransportListenError as e:
      listenErrCalled = true
      check:
        e.ma == mAddrs[1]
        e.parent == exc[1][1]

    check listenErrCalled

    echo "handledTransportErrs0:"
    for ma, ex in handledTransportErrs0:
      echo "ma: ", $ma, ", ex: ", ex.msg

    echo "handledTransportErrs1:"
    for ma, ex in handledTransportErrs1:
      echo "ma: ", $ma, ", ex: ", ex.msg

    check:
      handledTransportErrs0 == [(mAddrs[0], exc[0][0]), (mAddrs[1], exc[0][1]), (mAddrs[2], exc[0][2])].toTable()
      handledTransportErrs1 == [(mAddrs[1], exc[1][1])].toTable()

    await switch.stop()

  asyncTest "transport0 / transport2 optimistic, transport1 pessimistic - transport1 exception re-raised and transport2 should not start":
    var
      handledTransportErrs0 = initTable[MultiAddress, ref CatchableError]()
      handledTransportErrs1 = initTable[MultiAddress, ref CatchableError]()
    let
      # excXY, where X = MockTransport index, Y = transport exception index
      exc = buildExceptions(2, 2)

      transportListenError0 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs0[ma] = ex
          # optimistic transport multiaddress failure
          return nil

      transportListenError1 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          handledTransportErrs1[ma] = ex
          return newTransportListenError(ma, ex)

      transportListenError2 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =

          # should not get here as switch is pessimistic so will stop at first
          # failed transport (transpor1)
          fail()

      transportStartMock0 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              if i == 1:
                raise exc[0][i]
              else:
                continue
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              if not err.isNil:
                raise err

      transportStartMock1 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            try:
              if i == 0:
                raise exc[1][i]
              else:
                continue
            except CatchableError as e:
              let err = await self.listenError(ma, e)
              if not err.isNil:
                raise err

      transportStartMock2 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          # should not start transpor2 as transport1 should fail pessimistically
          fail()

      mockTransport0 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock0,
            listenError = transportListenError0)
          except: return

      mockTransport1 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock1,
            listenError = transportListenError1)
          except: return

      mockTransport2 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock2,
            listenError = transportListenError2)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport0) # Use MockTransport 0 as transport
        .withTransport(mockTransport1) # Use MockTransport 1 as transport
        .withTransport(mockTransport2) # Use MockTransport 2 as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    try:
      await switch.start()
    except TransportListenError as e:
      check:
        e.ma == mAddrs[0]
        e.parent == exc[1][0]

    echo "handledTransportErrs0:"
    for ma, ex in handledTransportErrs0:
      echo "ma: ", $ma, ", ex: ", ex.msg

    echo "handledTransportErrs1:"
    for ma, ex in handledTransportErrs1:
      echo "ma: ", $ma, ", ex: ", ex.msg

    check:
      handledTransportErrs0 == [(mAddrs[1], exc[0][1])].toTable()
      handledTransportErrs1 == [(mAddrs[0], exc[1][0])].toTable()

    await switch.stop()

  asyncTest "no exceptions raised, listenError should not be called":
    let
      transportListenError0 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =
          fail()

      transportListenError1 =
        proc(
            ma: MultiAddress,
            ex: ref CatchableError): Future[ref TransportListenError] {.async.} =
          fail()

      transportStartMock0 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            continue

      transportStartMock1 =
        proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.async.} =
          for i, ma in addrs:
            continue

      mockTransport0 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock0,
            listenError = transportListenError0)
          except: return

      mockTransport1 =
        proc(upgr: Upgrade): Transport {.raises: [Defect].} =
          # try/except here to keep the compiler happy. `startMock` can raise
          # an exception if called, but it is not actually called in `new`, so
          # we can wrap it in try/except to tell the compiler the exceptions
          # won't bubble up to `TransportProvider`.
          try: return MockTransport.new(
            upgr,
            startMock = transportStartMock1,
            listenError = transportListenError1)
          except: return

      mAddrs = buildLocalTcpAddrs(3)

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withTransport(mockTransport0) # Use MockTransport 0 as transport
        .withTransport(mockTransport1) # Use MockTransport 1 as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    try:
      await switch.start()
    except TransportListenError:
      # because transport.listenError should never be called, we shouldn't
      # expect an error to be raised from switch.start
      fail()

    await switch.stop()

  asyncTest "unhandled addresses are filtered":
    let
      transport = proc(upgr: Upgrade): Transport {.raises: [Defect].} =
        # try/except here to keep the compiler happy. `startMock` can raise
        # an exception if called, but it is not actually called in `new`, so
        # we can wrap it in try/except to tell the compiler the exceptions
        # won't bubble up to `TransportProvider`.
        try: return MockTransport.new(upgr)
        except: return
      maTcp1 = Multiaddress.init("/ip4/0.0.0.0/tcp/1").tryGet()
      maUdp = Multiaddress.init("/ip4/0.0.0.0/udp/0").tryGet()
      maTcp2 = Multiaddress.init("/ip4/0.0.0.0/tcp/2").tryGet()
      maP2p = Multiaddress.init("/p2p-circuit").tryGet()

      switch = SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(@[maTcp1, maUdp, maTcp2, maP2p])    # Our local address(es)
        .withTransport(transport) # Use MockTransport as transport
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    await switch.start()

    check switch.transports[0].addrs == @[maTcp1, maUdp, maTcp2]

    await switch.stop()

  asyncTest "should raise defect if no transports provided during construction":
    let
      mAddrs = buildLocalTcpAddrs(3)
      transport = (upgr: Upgrade) -> Transport => MockTransport.new(upgr)

    # builder should raise defect with addresses, but no transports
    expect LPDefect:
      discard SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withAddresses(mAddrs)    # Our local address(es)
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    # builder should raise defect with transports, but no addresses
    expect LPDefect:
      echo "[testswitch] building switch with no addresses"
      discard SwitchBuilder
        .new()
        .withRng(rng)       # Give the application RNG
        .withTransport(transport)
        .withAddresses(@[])
        .withMplex()        # Use Mplex as muxer
        .withNoise()        # Use Noise as secure manager
        .build()

    # should raise defect with addresses, but no transports
    var
      seckey = PrivateKey.random(rng[]).get()
      peerInfo = PeerInfo.new(seckey, mAddrs)
      identify = Identify.new(peerInfo)
      muxers = initTable[string, MuxerProvider]()

    muxers[MplexCodec] =
       MuxerProvider.new((conn: Connection) -> Muxer => Mplex.new(conn), MplexCodec)

    expect LPDefect:
      discard newSwitch(
        peerInfo = peerInfo,
        transports = @[],
        identity = identify,
        muxers = muxers,
        connManager = ConnManager.new(),
        ms = MultistreamSelect.new())

    # should raise defect with transports, but no addresses
    peerInfo.addrs = @[]
    expect LPDefect:
      discard newSwitch(
        peerInfo = peerInfo,
        transports = @[transport(Upgrade.new())],
        identity = identify,
        muxers = muxers,
        connManager = ConnManager.new(),
        ms = MultistreamSelect.new())
