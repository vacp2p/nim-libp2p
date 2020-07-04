{.used.}

import unittest, tables
import chronos
import stew/byteutils
import nimcrypto/sysrand
import ../libp2p/[errors,
                  switch,
                  multistream,
                  standard_setup,
                  stream/bufferstream,
                  protocols/identify,
                  stream/connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress,
                  peerinfo,
                  crypto/crypto,
                  protocols/protocol,
                  muxers/muxer,
                  muxers/mplex/mplex,
                  muxers/mplex/types,
                  protocols/secure/secio,
                  protocols/secure/secure,
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
      await conn.writeLp("Hello!")
      let msg = string.fromBytes(await conn.readLp(1024))
      check "Hello!" == msg
      await conn.close()

      await sleepAsync(2.seconds) # wait a little for cleanup to happen
      var bufferTracker = getTracker(BufferStreamTrackerName)
      # echo bufferTracker.dump()

      # plus 4 for the pubsub streams
      check (BufferStreamTracker(bufferTracker).opened ==
        (BufferStreamTracker(bufferTracker).closed + 4.uint64))

      # var connTracker = getTracker(ConnectionTrackerName)
      # echo connTracker.dump()

      # plus 8 is for the secured connection and the socket
      # and the pubsub streams that won't clean up until
      # `disconnect()` or `stop()`
      # check (ConnectionTracker(connTracker).opened ==
      #   (ConnectionTracker(connTracker).closed + 8.uint64))

      await allFuturesThrowing(
        done.wait(5.seconds),
        switch1.stop(),
        switch2.stop(),
      )

      # this needs to go at end
      await allFuturesThrowing(awaiters)

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
      check switch1.peerInfo.id in switch2.connections

      let conn = await switch2.dial(switch1.peerInfo, TestCodec)

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

      check switch1.connections[switch2.peerInfo.id].len > 0
      check switch2.connections[switch1.peerInfo.id].len > 0

      await sleepAsync(100.millis)
      await switch2.disconnect(switch1.peerInfo)

      await sleepAsync(2.seconds)
      var bufferTracker = getTracker(BufferStreamTrackerName)
      # echo bufferTracker.dump()
      check bufferTracker.isLeaked() == false

      # var connTracker = getTracker(ConnectionTrackerName)
      # echo connTracker.dump()
      # check connTracker.isLeaked() == false

      check switch2.peerInfo.id notin switch1.connections
      check switch1.peerInfo.id notin switch2.connections

      await allFuturesThrowing(
        switch1.stop(),
        switch2.stop())
      await allFuturesThrowing(awaiters)

    waitFor(testSwitch())

  # test "e2e: handle read + secio fragmented":
  #   proc testListenerDialer(): Future[bool] {.async.} =
  #     let
  #       server: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
  #       serverInfo = PeerInfo.init(PrivateKey.random(ECDSA), [server])
  #       serverNoise = newSecio(serverInfo.privateKey)
  #       readTask = newFuture[void]()

  #     var hugePayload = newSeq[byte](0x1200000)
  #     check randomBytes(hugePayload) == hugePayload.len
  #     trace "Sending huge payload", size = hugePayload.len

  #     proc connHandler(conn: Connection) {.async, gcsafe.} =
  #       let sconn = await serverNoise.secure(conn)
  #       defer:
  #         await sconn.close()
  #       let msg = await sconn.read(0x1200000)
  #       check msg == hugePayload
  #       readTask.complete()

  #     let
  #       transport1: TcpTransport = TcpTransport.init()
  #     asyncCheck await transport1.listen(server, connHandler)

  #     let
  #       transport2: TcpTransport = TcpTransport.init()
  #       clientInfo = PeerInfo.init(PrivateKey.random(ECDSA), [transport1.ma])
  #       clientNoise = newSecio(clientInfo.privateKey)
  #       conn = await transport2.dial(transport1.ma)
  #       sconn = await clientNoise.secure(conn)

  #     await sconn.write(hugePayload)
  #     await readTask

  #     await sconn.close()
  #     await conn.close()
  #     await transport2.close()
  #     await transport1.close()

  #     result = true

  #   check:
  #     waitFor(testListenerDialer()) == true
