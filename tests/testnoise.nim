## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.used.}

import tables, bearssl
import chronos, stew/byteutils
import chronicles
import ../libp2p/crypto/crypto
import ../libp2p/[switch,
                  errors,
                  multistream,
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
                  protocols/secure/noise,
                  protocols/secure/secio,
                  protocols/secure/secure,
                  upgrademngrs/muxedupgrade,
                  connmanager]
import ./helpers

const
  TestCodec = "/test/proto/1.0.0"

type
  TestProto = ref object of LPProtocol

method init(p: TestProto) {.gcsafe, raises: [Defect].} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.writeLp("Hello!")
    await conn.close()

  p.codec = TestCodec
  p.handler = handle

proc createSwitch(ma: MultiAddress; outgoing: bool, secio: bool = false): (Switch, PeerInfo) =
  var
    privateKey = PrivateKey.random(ECDSA, rng[]).get()
    peerInfo = PeerInfo.new(privateKey)
  peerInfo.addrs.add(ma)

  proc createMplex(conn: Connection): Muxer =
    result = Mplex.new(conn)

  let
    identify = Identify.new(peerInfo)
    mplexProvider = MuxerProvider.new(createMplex, MplexCodec)
    muxers = [(MplexCodec, mplexProvider)].toTable()
    secureManagers = if secio:
      [Secure(Secio.new(rng, privateKey))]
    else:
      [Secure(Noise.new(rng, privateKey, outgoing = outgoing))]
    connManager = ConnManager.new()
    ms = MultistreamSelect.new()
    muxedUpgrade = MuxedUpgrade.new(identify, muxers, secureManagers, connManager, ms)
    transports = @[Transport(TcpTransport.new(upgrade = muxedUpgrade))]

  let switch = newSwitch(
      peerInfo,
      transports,
      identify,
      muxers,
      secureManagers,
      connManager,
      ms)
  result = (switch, peerInfo)

suite "Noise":
  teardown:
    checkTrackers()

  asyncTest "e2e: handle write + noise":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverNoise = Noise.new(rng, serverPrivKey, outgoing = false)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(server)

    proc acceptHandler() {.async.} =
      let conn = await transport1.accept()
      let sconn = await serverNoise.secure(conn, false)
      try:
        await sconn.write("Hello!")
      finally:
        await sconn.close()
        await conn.close()

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(rng, clientPrivKey, outgoing = true)
      conn = await transport2.dial(transport1.addrs[0])

    conn.peerId = serverInfo.peerId
    let sconn = await clientNoise.secure(conn, true)

    var msg = newSeq[byte](6)
    await sconn.readExactly(addr msg[0], 6)

    await sconn.close()
    await conn.close()
    await acceptFut
    await transport1.stop()
    await transport2.stop()

    check string.fromBytes(msg) == "Hello!"

  asyncTest "e2e: handle write + noise (wrong prologue)":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverNoise = Noise.new(rng, serverPrivKey, outgoing = false)

    let
      transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())

    asyncSpawn transport1.start(server)

    proc acceptHandler() {.async, gcsafe.} =
      var conn: Connection
      try:
        conn = await transport1.accept()
        discard await serverNoise.secure(conn, false)
      except CatchableError:
        discard
      finally:
        await conn.close()

    let
      handlerWait = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(rng, clientPrivKey, outgoing = true, commonPrologue = @[1'u8, 2'u8, 3'u8])
      conn = await transport2.dial(transport1.addrs[0])
    conn.peerId = serverInfo.peerId

    var sconn: Connection = nil
    expect(NoiseDecryptTagError):
      sconn = await clientNoise.secure(conn, true)

    await conn.close()
    await handlerWait
    await transport1.stop()
    await transport2.stop()

  asyncTest "e2e: handle read + noise":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverNoise = Noise.new(rng, serverPrivKey, outgoing = false)
      readTask = newFuture[void]()

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(server)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport1.accept()
      let sconn = await serverNoise.secure(conn, false)
      defer:
        await sconn.close()
        await conn.close()

      var msg = newSeq[byte](6)
      await sconn.readExactly(addr msg[0], 6)
      check string.fromBytes(msg) == "Hello!"

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(rng, clientPrivKey, outgoing = true)
      conn = await transport2.dial(transport1.addrs[0])
    conn.peerId = serverInfo.peerId
    let sconn = await clientNoise.secure(conn, true)

    await sconn.write("Hello!")
    await acceptFut
    await sconn.close()
    await conn.close()
    await transport1.stop()
    await transport2.stop()

  asyncTest "e2e: handle read + noise fragmented":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverNoise = Noise.new(rng, serverPrivKey, outgoing = false)
      readTask = newFuture[void]()

    var hugePayload = newSeq[byte](0xFFFFF)
    brHmacDrbgGenerate(rng[], hugePayload)
    trace "Sending huge payload", size = hugePayload.len

    let
      transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      listenFut = transport1.start(server)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport1.accept()
      let sconn = await serverNoise.secure(conn, false)
      defer:
        await sconn.close()
      let msg = await sconn.readLp(1024*1024)
      check msg == hugePayload
      readTask.complete()

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(rng, clientPrivKey, outgoing = true)
      conn = await transport2.dial(transport1.addrs[0])
    conn.peerId = serverInfo.peerId
    let sconn = await clientNoise.secure(conn, true)

    await sconn.writeLp(hugePayload)
    await readTask

    await sconn.close()
    await conn.close()
    await acceptFut
    await transport2.stop()
    await transport1.stop()
    await listenFut

  asyncTest "e2e use switch dial proto string":
    let ma1 = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    let ma2 = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

    var peerInfo1, peerInfo2: PeerInfo
    var switch1, switch2: Switch

    (switch1, peerInfo1) = createSwitch(ma1, false)

    let testProto = new TestProto
    testProto.init()
    testProto.codec = TestCodec
    switch1.mount(testProto)
    (switch2, peerInfo2) = createSwitch(ma2, true)
    await switch1.start()
    await switch2.start()
    let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)
    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())

  asyncTest "e2e test wrong secure negotiation":
    let ma1 = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    let ma2 = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

    var peerInfo1, peerInfo2: PeerInfo
    var switch1, switch2: Switch

    (switch1, peerInfo1) = createSwitch(ma1, false)

    let testProto = new TestProto
    testProto.init()
    testProto.codec = TestCodec
    switch1.mount(testProto)
    (switch2, peerInfo2) = createSwitch(ma2, true, true) # secio, we want to fail
    await switch1.start()
    await switch2.start()
    expect(UpgradeFailedError):
      let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())
