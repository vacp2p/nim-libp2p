{.used.}

import options, bearssl, chronos
import stew/byteutils
import ../libp2p/[protocols/relay,
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

proc writeLp*(s: StreamTransport, msg: string | seq[byte]): Future[int] {.gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  result = s.write(buf.buffer)

proc readLp*(s: StreamTransport): Future[seq[byte]] {.async, gcsafe.} =
  ## read length prefixed msg
  var
    size: uint
    length: int
    res: VarintResult[void]
  result = newSeq[byte](10)

  for i in 0..<len(result):
    await s.readExactly(addr result[i], 1)
    res = LP.getUVarint(result.toOpenArray(0, i), length, size)
    if res.isOk():
      break
  res.expect("Valid varint")
  result.setLen(size)
  if size > 0.uint:
    await s.readExactly(addr result[0], int(size))

suite "Circuit Relay":
  asyncTeardown:
    await allFutures(src.stop(), dst.stop(), rel.stop())
    checkTrackers()

  var
    protos {.threadvar.}: seq[string]
    customProto {.threadvar.}: LPProtocol
    ma {.threadvar.}: MultiAddress
    src {.threadvar.}: Switch
    dst {.threadvar.}: Switch
    rel {.threadvar.}: Switch
    relaySrc {.threadvar.}: Relay
    relayDst {.threadvar.}: Relay
    relayRel {.threadvar.}: Relay
    conn {.threadVar.}: Connection
    msg {.threadVar.}: ProtoBuffer
    rcv {.threadVar.}: Option[RelayMessage]

  proc createMsg(
    msgType: Option[RelayType] = RelayType.none,
    status: Option[RelayStatus] = RelayStatus.none,
    src: Option[RelayPeer] = RelayPeer.none,
    dst: Option[RelayPeer] = RelayPeer.none): ProtoBuffer =
    encodeMsg(RelayMessage(msgType: msgType, srcPeer: src, dstPeer: dst, status: status))

  proc checkMsg(msg: Option[RelayMessage],
    msgType: Option[RelayType] = none[RelayType](),
    status: Option[RelayStatus] = none[RelayStatus](),
    src: Option[RelayPeer] = none[RelayPeer](),
    dst: Option[RelayPeer] = none[RelayPeer]()): bool =
    msg.isSome and msg.get == RelayMessage(msgType: msgType, srcPeer: src, dstPeer: dst, status: status)

  proc customHandler(conn: Connection, proto: string) {.async.} =
    check "line1" == string.fromBytes(await conn.readLp(1024))
    await conn.writeLp("line2")
    check "line3" == string.fromBytes(await conn.readLp(1024))
    await conn.writeLp("line4")
    await conn.close()

  asyncSetup:
    # Create a custom prototype
    protos = @[ "/customProto", RelayCodec ]
    customProto = new LPProtocol
    customProto.handler = customHandler
    customProto.codec = protos[0]
    ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

    src = newStandardSwitch()
    rel = newStandardSwitch()
    dst = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[ ma ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    relaySrc = Relay.new(src, false)
    relayDst = Relay.new(dst, false)
    relayRel = Relay.new(rel, true)

    src.mount(relaySrc)
    dst.mount(relayDst)
    dst.mount(customProto)
    rel.mount(relayRel)

    src.addTransport(RelayTransport.new(relaySrc))
    dst.addTransport(RelayTransport.new(relayDst))

    await src.start()
    await dst.start()
    await rel.start()

  asyncTest "Handle CanHop":
    msg = createMsg(some(CanHop))
    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(RelayStatus.Success))

    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantSpeakRelay))

    await conn.close()

  asyncTest "Malformed":
    conn = await rel.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Status))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    await conn.close()
    check rcv.checkMsg(some(Status), some(MalformedMessage))

  asyncTest "Handle Stop Error":
    conn = await rel.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Stop),
      none(RelayStatus),
      none(RelayPeer),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(StopSrcMultiaddrInvalid))

    conn = await rel.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Stop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(StopDstMultiaddrInvalid))

    conn = await rel.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Stop),
      none(RelayStatus),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    await conn.close()
    check rcv.checkMsg(some(Status), some(StopDstMultiaddrInvalid))

  asyncTest "Handle Hop Error":
    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantSpeakRelay))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      none(RelayPeer),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopSrcMultiaddrInvalid))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopSrcMultiaddrInvalid))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopDstMultiaddrInvalid))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: rel.peerInfo.peerId, addrs: rel.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantRelayToSelf))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: rel.peerInfo.peerId, addrs: rel.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantRelayToSelf))

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopNoConnToDst))

    await rel.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)

    relayRel.maxCircuit = 0
    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantSpeakRelay))
    relayRel.maxCircuit = relay.MaxCircuit
    await conn.close()

    relayRel.maxCircuitPerPeer = 0
    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantSpeakRelay))
    relayRel.maxCircuitPerPeer = relay.MaxCircuitPerPeer
    await conn.close()

    let dst2 = newStandardSwitch()
    await dst2.start()
    await rel.connect(dst2.peerInfo.peerId, dst2.peerInfo.addrs)

    conn = await src.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayCodec)
    msg = createMsg(some(RelayType.Hop),
      none(RelayStatus),
      some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      some(RelayPeer(peerId: dst2.peerInfo.peerId, addrs: dst2.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = relay.decodeMsg(await conn.readLp(relay.MsgSize))
    check rcv.checkMsg(some(Status), some(HopCantDialDst))
    await allFutures(dst2.stop())

  asyncTest "Dial Peer":
    let maStr = $rel.peerInfo.addrs[0] & "/p2p/" & $rel.peerInfo.peerId & "/p2p-circuit/p2p/" & $dst.peerInfo.peerId
    let maddr = MultiAddress.init(maStr).tryGet()
    await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
    await rel.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    await conn.writeLp("line1")
    check string.fromBytes(await conn.readLp(1024)) == "line2"

    await conn.writeLp("line3")
    check string.fromBytes(await conn.readLp(1024)) == "line4"

  asyncTest "SwitchBuilder withRelay":
    let
      maSrc = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      maRel = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      maDst = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      srcWR = SwitchBuilder.new()
        .withRng(newRng())
        .withAddresses(@[ maSrc ])
        .withTcpTransport()
        .withMplex()
        .withNoise()
        .withRelayTransport(false)
        .build()
      relWR = SwitchBuilder.new()
        .withRng(newRng())
        .withAddresses(@[ maRel ])
        .withTcpTransport()
        .withMplex()
        .withNoise()
        .withRelayTransport(true)
        .build()
      dstWR = SwitchBuilder.new()
        .withRng(newRng())
        .withAddresses(@[ maDst ])
        .withTcpTransport()
        .withMplex()
        .withNoise()
        .withRelayTransport(false)
        .build()

    dstWR.mount(customProto)

    await srcWR.start()
    await dstWR.start()
    await relWR.start()

    let maStr = $relWR.peerInfo.addrs[0] & "/p2p/" & $relWR.peerInfo.peerId & "/p2p-circuit/p2p/" & $dstWR.peerInfo.peerId
    let maddr = MultiAddress.init(maStr).tryGet()
    await srcWR.connect(relWR.peerInfo.peerId, relWR.peerInfo.addrs)
    await relWR.connect(dstWR.peerInfo.peerId, dstWR.peerInfo.addrs)
    conn = await srcWR.dial(dstWR.peerInfo.peerId, @[ maddr ], protos[0])

    await conn.writeLp("line1")
    check string.fromBytes(await conn.readLp(1024)) == "line2"

    await conn.writeLp("line3")
    check string.fromBytes(await conn.readLp(1024)) == "line4"

    await allFutures(srcWR.stop(), dstWR.stop(), relWR.stop())

  asynctest "Bad MultiAddress":
    await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
    await rel.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    expect(CatchableError):
      let maStr = $rel.peerInfo.addrs[0] & "/p2p/" & $rel.peerInfo.peerId & "/p2p/" & $dst.peerInfo.peerId
      let maddr = MultiAddress.init(maStr).tryGet()
      conn = await src.dial(dst.peerInfo.peerId, @[ maddr ], protos[0])

    expect(CatchableError):
      let maStr = $rel.peerInfo.addrs[0] & "/p2p/" & $rel.peerInfo.peerId
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
