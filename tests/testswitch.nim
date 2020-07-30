{.used.}

import unittest
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
                  muxers/muxer,
                  muxers/mplex/mplex,
                  stream/lpstream]
import ./helpers

const
  TestCodec = "/test/proto/1.0.0"

type
  TestProto = ref object of LPProtocol

suite "Switch":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "e2e use switch dial proto string":
    proc testSwitch() {.async, gcsafe.} =
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

    waitFor(testSwitch())

  test "e2e should not leak bufferstreams and connections on channel close":
    proc testSwitch() {.async, gcsafe.} =
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

      await sleepAsync(2.seconds) # wait a little for cleanup to happen
      var bufferTracker = getTracker(BufferStreamTrackerName)
      # echo bufferTracker.dump()

      check (BufferStreamTracker(bufferTracker).opened ==
        (BufferStreamTracker(bufferTracker).closed))

      var connTracker = getTracker(ConnectionTrackerName)
      # echo connTracker.dump()

      # plus 4 is for the secured connection and the socket
      # and the pubsub streams that won't clean up until
      # `disconnect()` or `stop()`
      check (ConnectionTracker(connTracker).opened ==
        (ConnectionTracker(connTracker).closed + 4.uint64))

      await allFuturesThrowing(
        done.wait(5.seconds),
        switch1.stop(),
        switch2.stop(),
      )

      # this needs to go at end
      await allFuturesThrowing(awaiters)

      check not switch1.isConnected(switch2.peerInfo)
      check not switch2.isConnected(switch1.peerInfo)

    waitFor(testSwitch())

  test "e2e use connect then dial":
    proc testSwitch(): Future[bool] {.async, gcsafe.} =
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

      try:
        await conn.writeLp("Hello!")
        let msg = string.fromBytes(await conn.readLp(1024))
        check "Hello!" == msg
        result = true
      except LPStreamError:
        result = false

      await allFuturesThrowing(
        conn.close(),
        switch1.stop(),
        switch2.stop()
      )
      await allFuturesThrowing(awaiters)

      check not switch1.isConnected(switch2.peerInfo)
      check not switch2.isConnected(switch1.peerInfo)

    check:
      waitFor(testSwitch()) == true

  test "e2e should not leak on peer disconnect":
    proc testSwitch() {.async, gcsafe.} =
      var awaiters: seq[Future[void]]

      let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
      let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
      awaiters.add(await switch1.start())
      awaiters.add(await switch2.start())

      await switch2.connect(switch1.peerInfo)

      check switch1.isConnected(switch2.peerInfo)
      check switch2.isConnected(switch1.peerInfo)

      await sleepAsync(100.millis)
      await switch2.disconnect(switch1.peerInfo)
      await sleepAsync(2.seconds)

      check not switch1.isConnected(switch2.peerInfo)
      check not switch2.isConnected(switch1.peerInfo)

      var bufferTracker = getTracker(BufferStreamTrackerName)
      # echo bufferTracker.dump()
      check bufferTracker.isLeaked() == false

      var connTracker = getTracker(ConnectionTrackerName)
      # echo connTracker.dump()
      check connTracker.isLeaked() == false

      await allFuturesThrowing(
        switch1.stop(),
        switch2.stop())
      await allFuturesThrowing(awaiters)

    waitFor(testSwitch())

  test "e2e should trigger hooks":
    proc testSwitch() {.async, gcsafe.} =
      var awaiters: seq[Future[void]]

      let switch1 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])
      let switch2 = newStandardSwitch(secureManagers = [SecureProtocol.Secio])

      var step = 0
      var cycles: set[Lifecycle]
      proc hook(peer: PeerInfo, cycle: Lifecycle) {.async, gcsafe.} =
        cycles = cycles + {cycle}
        case step:
        of 0:
          check cycle == Lifecycle.Connected
          check if not(isNil(peer)):
                peer.peerId == switch2.peerInfo.peerId
              else:
                true
        of 1:
          assert(isNil(peer) == false)
          check:
            cycle == Lifecycle.Upgraded
            peer.peerId == switch2.peerInfo.peerId
        of 2:
          check:
            cycle == Lifecycle.Disconnected

          check if not(isNil(peer)):
              peer.peerId == switch2.peerInfo.peerId
            else:
              true
        else:
          echo "unkown cycle! ", $cycle
          check false

        step.inc()

      switch1.addHook(hook, Lifecycle.Connected)
      switch1.addHook(hook, Lifecycle.Upgraded)
      switch1.addHook(hook, Lifecycle.Disconnected)

      awaiters.add(await switch1.start())
      awaiters.add(await switch2.start())

      await switch2.connect(switch1.peerInfo)

      check switch1.isConnected(switch2.peerInfo)
      check switch2.isConnected(switch1.peerInfo)

      await sleepAsync(100.millis)
      await switch2.disconnect(switch1.peerInfo)
      await sleepAsync(2.seconds)

      check not switch1.isConnected(switch2.peerInfo)
      check not switch2.isConnected(switch1.peerInfo)

      var bufferTracker = getTracker(BufferStreamTrackerName)
      # echo bufferTracker.dump()
      check bufferTracker.isLeaked() == false

      var connTracker = getTracker(ConnectionTrackerName)
      # echo connTracker.dump()
      check connTracker.isLeaked() == false

      check:
        cycles == {
          Lifecycle.Connected,
          Lifecycle.Upgraded,
          Lifecycle.Disconnected
        }

      await allFuturesThrowing(
        switch1.stop(),
        switch2.stop())
      await allFuturesThrowing(awaiters)

    waitFor(testSwitch())
