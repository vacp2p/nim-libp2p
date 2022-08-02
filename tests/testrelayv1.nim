{.used.}

import options, bearssl, chronos
import stew/byteutils
import ../libp2p/[protocols/relay/relay,
                  protocols/relay/client,
                  protocols/relay/messages,
                  protocols/relay/utils,
                  protocols/relay/rtransport,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
                  transports/transport,
                  switch,
                  builders,
                  upgrademngrs/upgrade,
                  varint,
                  daemon/daemonapi]
import ./helpers

proc new(T: typedesc[RelayTransport], relay: Relay): T =
  T.new(relay = relay, upgrader = relay.switch.transports[0].upgrader)

suite "Circuit Relay":
  asyncTeardown:
    await allFutures(src.stop(), dst.stop(), srelay.stop())
    checkTrackers()

  var
    protos {.threadvar.}: seq[string]
    customProto {.threadvar.}: LPProtocol
    ma {.threadvar.}: MultiAddress
    src {.threadvar.}: Switch
    dst {.threadvar.}: Switch
    srelay {.threadvar.}: Switch
    clSrc {.threadvar.}: RelayClient
    clDst {.threadvar.}: RelayClient
    r {.threadvar.}: Relay
    conn {.threadvar.}: Connection
    msg {.threadvar.}: ProtoBuffer
    rcv {.threadvar.}: Option[RelayMessage]

  proc createMsg(
    msgType: Option[RelayType] = RelayType.none,
    status: Option[StatusV1] = StatusV1.none,
    src: Option[RelayPeer] = RelayPeer.none,
    dst: Option[RelayPeer] = RelayPeer.none): ProtoBuffer =
    encode(RelayMessage(msgType: msgType, srcPeer: src, dstPeer: dst, status: status))

  proc checkMsg(msg: Option[RelayMessage],
    msgType: Option[RelayType] = none[RelayType](),
    status: Option[StatusV1] = none[StatusV1](),
    src: Option[RelayPeer] = none[RelayPeer](),
    dst: Option[RelayPeer] = none[RelayPeer]()) =
    check: msg.isSome
    let m = msg.get()
    check: m.msgType == msgType
    check: m.status == status
    check: m.srcPeer == src
    check: m.dstPeer == dst

  proc customHandler(conn: Connection, proto: string) {.async.} =
    check "line1" == string.fromBytes(await conn.readLp(1024))
    await conn.writeLp("line2")
    check "line3" == string.fromBytes(await conn.readLp(1024))
    await conn.writeLp("line4")
    await conn.close()

  asyncSetup:
    # Create a custom prototype
    protos = @[ "/customProto", RelayV1Codec ]
    customProto = new LPProtocol
    customProto.handler = customHandler
    customProto.codec = protos[0]

    ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    clSrc = RelayClient.new()
    clDst = RelayClient.new()
    r = Relay.new(circuitRelayV1=true)
    src = SwitchBuilder.new()
      .withRng(newRng())
      .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withCircuitRelay(clSrc)
      .build()
    dst = SwitchBuilder.new()
      .withRng(newRng())
      .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withCircuitRelay(clDst)
      .build()
    srelay = SwitchBuilder.new()
      .withRng(newRng())
      .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withCircuitRelay(r)
      .build()

    dst.mount(customProto)

    await src.start()
    await dst.start()
    await srelay.start()

  asyncTest "Handle CanHop":
    msg = createMsg(some(CanHop))
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(StatusV1.Success))

    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantSpeakRelay))

    await conn.close()

  asyncTest "Malformed":
    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Status))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    await conn.close()
    rcv.checkMsg(some(RelayType.Status), some(StatusV1.MalformedMessage))

  asyncTest "Handle Stop Error":
    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Stop),
      none(StatusV1),
      none(RelayPeer),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(StopSrcMultiaddrInvalid))

    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Stop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(StopDstMultiaddrInvalid))

    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Stop),
      none(StatusV1),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    await conn.close()
    rcv.checkMsg(some(RelayType.Status), some(StopDstMultiaddrInvalid))

  asyncTest "Handle Hop Error":
    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantSpeakRelay))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      none(RelayPeer),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopSrcMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopSrcMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopDstMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: srelay.peerInfo.peerId, addrs: srelay.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantRelayToSelf))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: srelay.peerInfo.peerId, addrs: srelay.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantRelayToSelf))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopNoConnToDst))

    await srelay.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)

    var tmp = r.maxCircuit
    r.maxCircuit = 0
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantSpeakRelay))
    r.maxCircuit = tmp
    await conn.close()

    tmp = r.maxCircuitPerPeer
    r.maxCircuitPerPeer = 0
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantSpeakRelay))
    r.maxCircuitPerPeer = tmp
    await conn.close()

    let dst2 = newStandardSwitch()
    await dst2.start()
    await srelay.connect(dst2.peerInfo.peerId, dst2.peerInfo.addrs)

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(some(RelayType.Hop),
      none(StatusV1),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: dst2.peerInfo.peerId, addrs: dst2.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(some(RelayType.Status), some(HopCantDialDst))
    await allFutures(dst2.stop())

  asyncTest "Dial Peer":
    let maStr = $srelay.peerInfo.addrs[0] & "/p2p/" & $srelay.peerInfo.peerId & "/p2p-circuit/p2p/" & $dst.peerInfo.peerId
    let maddr = MultiAddress.init(maStr).tryGet()
    await src.connect(srelay.peerInfo.peerId, srelay.peerInfo.addrs)
    await srelay.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    await conn.writeLp("line1")
    check string.fromBytes(await conn.readLp(1024)) == "line2"

    await conn.writeLp("line3")
    check string.fromBytes(await conn.readLp(1024)) == "line4"

  asyncTest "Bad MultiAddress":
    await src.connect(srelay.peerInfo.peerId, srelay.peerInfo.addrs)
    await srelay.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    expect(CatchableError):
      let maStr = $srelay.peerInfo.addrs[0] & "/p2p/" & $srelay.peerInfo.peerId & "/p2p/" & $dst.peerInfo.peerId
      let maddr = MultiAddress.init(maStr).tryGet()
      conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    expect(CatchableError):
      let maStr = $srelay.peerInfo.addrs[0] & "/p2p/" & $srelay.peerInfo.peerId
      let maddr = MultiAddress.init(maStr).tryGet()
      conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    expect(CatchableError):
      let maStr = "/ip4/127.0.0.1"
      let maddr = MultiAddress.init(maStr).tryGet()
      conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    expect(CatchableError):
      let maStr = $dst.peerInfo.peerId
      let maddr = MultiAddress.init(maStr).tryGet()
      conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])
