{.used.}

import unittest, tables
import chronos
import chronicles
import nimcrypto/sysrand
import ../libp2p/[errors,
                  switch,
                  multistream,
                  stream/bufferstream,
                  protocols/identify,
                  connection,
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

proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
  var peerInfo: PeerInfo = PeerInfo.init(PrivateKey.random(ECDSA).tryGet())
  peerInfo.addrs.add(ma)
  let identify = newIdentify(peerInfo)

  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(TcpTransport.init())]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let secureManagers = [(SecioCodec, Secure(newSecio(peerInfo.privateKey)))].toTable()
  let switch = newSwitch(peerInfo,
                         transports,
                         identify,
                         muxers,
                         secureManagers)
  result = (switch, peerInfo)

suite "Switch":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "e2e use switch dial proto string":
    proc testSwitch() {.async, gcsafe.} =
      let ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      let ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var peerInfo1, peerInfo2: PeerInfo
      var switch1, switch2: Switch
      var awaiters: seq[Future[void]]

      (switch1, peerInfo1) = createSwitch(ma1)

      let done = newFuture[void]()

      proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
        let msg = cast[string](await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
        await conn.close()
        done.complete()

      let testProto = new TestProto
      testProto.codec = TestCodec
      testProto.handler = handle
      switch1.mount(testProto)

      (switch2, peerInfo2) = createSwitch(ma2)
      awaiters.add(await switch1.start())
      awaiters.add(await switch2.start())

      let conn = await switch2.dial(switch1.peerInfo, TestCodec)

      await conn.writeLp("Hello!")
      let msg = cast[string](await conn.readLp(1024))
      check "Hello!" == msg

      await all(
        done.wait(5.seconds) #[if OK won't happen!!]#,
        conn.close(),
        switch1.stop(),
        switch2.stop(),
      )

      # this needs to go at end
      await all(awaiters)

    waitFor(testSwitch())

  test "e2e use switch no proto string":
    proc testSwitch(): Future[bool] {.async, gcsafe.} =
      let ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      let ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var peerInfo1, peerInfo2: PeerInfo
      var switch1, switch2: Switch
      var awaiters: seq[Future[void]]

      (switch1, peerInfo1) = createSwitch(ma1)

      proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
        let msg = cast[string](await conn.readLp(1024))
        check "Hello!" == msg
        await conn.writeLp("Hello!")
        await conn.close()

      let testProto = new TestProto
      testProto.codec = TestCodec
      testProto.handler = handle
      switch1.mount(testProto)

      (switch2, peerInfo2) = createSwitch(ma2)
      awaiters.add(await switch1.start())
      awaiters.add(await switch2.start())
      await switch2.connect(switch1.peerInfo)
      let conn = await switch2.dial(switch1.peerInfo, TestCodec)

      try:
        await conn.writeLp("Hello!")
        let msg = cast[string](await conn.readLp(1024))
        check "Hello!" == msg
        result = true
      except LPStreamError:
        result = false

      await all(
        conn.close(),
        switch1.stop(),
        switch2.stop()
      )
      await all(awaiters)

    check:
      waitFor(testSwitch()) == true

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
