{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, stew/byteutils
import chronicles
import
  ../../libp2p/[
    switch,
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
    protocols/secure/plaintext,
    protocols/secure/secure,
    upgrademngrs/muxedupgrade,
    connmanager,
  ]
import ../helpers

const TestCodec = "/test/proto/1.0.0"

type TestProto = ref object of LPProtocol

{.push raises: [].}

method init(p: TestProto) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      let msg = string.fromBytes(await conn.readLp(1024))
      check "Hello!" == msg
      await conn.writeLp("Hello!")
    except CancelledError as e:
      raise e
    except CatchableError:
      check false # should not be here
    finally:
      await conn.close()

  p.codec = TestCodec
  p.handler = handle

{.pop.}

proc createSwitch(
    ma: MultiAddress, outgoing: bool, plaintext: bool = false
): (Switch, PeerInfo) =
  var
    privateKey = PrivateKey.random(ECDSA, rng[]).get()
    peerInfo = PeerInfo.new(privateKey, @[ma])

  proc createMplex(conn: Connection): Muxer =
    result = Mplex.new(conn)

  let
    identify = Identify.new(peerInfo)
    peerStore = PeerStore.new(identify)
    mplexProvider = MuxerProvider.new(createMplex, MplexCodec)
    muxers = @[mplexProvider]
    secureManagers =
      if plaintext:
        [Secure(PlainText.new())]
      else:
        [Secure(Noise.new(rng, privateKey, outgoing = outgoing))]
    connManager = ConnManager.new()
    ms = MultistreamSelect.new()
    muxedUpgrade = MuxedUpgrade.new(muxers, secureManagers, ms)
    transports = @[Transport(TcpTransport.new(upgrade = muxedUpgrade))]

  let switch =
    newSwitch(peerInfo, transports, secureManagers, connManager, ms, peerStore)
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
      let sconn = await serverNoise.secure(conn, Opt.none(PeerId))
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

    let sconn = await clientNoise.secure(conn, Opt.some(serverInfo.peerId))

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

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())

    asyncSpawn transport1.start(server)

    proc acceptHandler() {.async.} =
      var conn: Connection
      try:
        conn = await transport1.accept()
        discard await serverNoise.secure(conn, Opt.none(PeerId))
      except CatchableError:
        discard
      finally:
        await conn.close()

    let
      handlerWait = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(
        rng, clientPrivKey, outgoing = true, commonPrologue = @[1'u8, 2'u8, 3'u8]
      )
      conn = await transport2.dial(transport1.addrs[0])

    var sconn: Connection = nil
    expect(NoiseDecryptTagError):
      sconn = await clientNoise.secure(conn, Opt.some(conn.peerId))

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

    proc acceptHandler() {.async.} =
      let conn = await transport1.accept()
      let sconn = await serverNoise.secure(conn, Opt.none(PeerId))
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
    let sconn = await clientNoise.secure(conn, Opt.some(serverInfo.peerId))

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
    hmacDrbgGenerate(rng[], hugePayload)
    trace "Sending huge payload", size = hugePayload.len

    let
      transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      listenFut = transport1.start(server)

    proc acceptHandler() {.async.} =
      let conn = await transport1.accept()
      let sconn = await serverNoise.secure(conn, Opt.none(PeerId))
      defer:
        await sconn.close()
      let msg = await sconn.readLp(1024 * 1024)
      check msg == hugePayload
      readTask.complete()

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientNoise = Noise.new(rng, clientPrivKey, outgoing = true)
      conn = await transport2.dial(transport1.addrs[0])
    let sconn = await clientNoise.secure(conn, Opt.some(serverInfo.peerId))

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
    let conn =
      await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)
    await conn.writeLp("Hello!")
    let msg = string.fromBytes(await conn.readLp(1024))
    check "Hello!" == msg
    await conn.close()

    await allFuturesThrowing(switch1.stop(), switch2.stop())

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
    expect(DialFailedError):
      let conn =
        await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

    await allFuturesThrowing(switch1.stop(), switch2.stop())
