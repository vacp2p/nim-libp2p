{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options, bearssl, chronos
import stew/byteutils
import ../libp2p/[protocols/connectivity/relay/relay,
                  protocols/connectivity/relay/client,
                  protocols/connectivity/relay/messages,
                  protocols/connectivity/relay/utils,
                  protocols/connectivity/relay/rtransport,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
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
    rcv {.threadvar.}: Opt[RelayMessage]

  proc createMsg(
    msgType: Opt[RelayType] = Opt.none(RelayType),
    status: Opt[StatusV1] = Opt.none(StatusV1),
    src: Opt[RelayPeer] = Opt.none(RelayPeer),
    dst: Opt[RelayPeer] = Opt.none(RelayPeer)): ProtoBuffer =
    encode(RelayMessage(msgType: msgType, srcPeer: src, dstPeer: dst, status: status))

  proc checkMsg(msg: Opt[RelayMessage],
    msgType: Opt[RelayType] = Opt.none(RelayType),
    status: Opt[StatusV1] = Opt.none(StatusV1),
    src: Opt[RelayPeer] = Opt.none(RelayPeer),
    dst: Opt[RelayPeer] = Opt.none(RelayPeer)) =
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
      .withRng(rng())
      .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withCircuitRelay(clSrc)
      .build()
    dst = SwitchBuilder.new()
      .withRng(rng())
      .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withCircuitRelay(clDst)
      .build()
    srelay = SwitchBuilder.new()
      .withRng(rng())
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
    msg = createMsg(Opt.some(CanHop))
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(StatusV1.Success))

    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantSpeakRelay))

    await conn.close()

  asyncTest "Malformed":
    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Status))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    await conn.close()
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(StatusV1.MalformedMessage))

  asyncTest "Handle Stop Error":
    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Stop),
      Opt.none(StatusV1),
      Opt.none(RelayPeer),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(StopSrcMultiaddrInvalid))

    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Stop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(StopDstMultiaddrInvalid))

    conn = await srelay.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Stop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    await conn.close()
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(StopDstMultiaddrInvalid))

  asyncTest "Handle Hop Error":
    conn = await src.dial(dst.peerInfo.peerId, dst.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantSpeakRelay))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.none(RelayPeer),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopSrcMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopSrcMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.none(RelayPeer))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopDstMultiaddrInvalid))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: srelay.peerInfo.peerId, addrs: srelay.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantRelayToSelf))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: srelay.peerInfo.peerId, addrs: srelay.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantRelayToSelf))

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: dst.peerInfo.peerId, addrs: dst.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopNoConnToDst))

    await srelay.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)

    var tmp = r.maxCircuit
    r.maxCircuit = 0
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantSpeakRelay))
    r.maxCircuit = tmp
    await conn.close()

    tmp = r.maxCircuitPerPeer
    r.maxCircuitPerPeer = 0
    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantSpeakRelay))
    r.maxCircuitPerPeer = tmp
    await conn.close()

    let dst2 = newStandardSwitch()
    await dst2.start()
    await srelay.connect(dst2.peerInfo.peerId, dst2.peerInfo.addrs)

    conn = await src.dial(srelay.peerInfo.peerId, srelay.peerInfo.addrs, RelayV1Codec)
    msg = createMsg(Opt.some(RelayType.Hop),
      Opt.none(StatusV1),
      Opt.some(RelayPeer(peerId: src.peerInfo.peerId, addrs: src.peerInfo.addrs)),
      Opt.some(RelayPeer(peerId: dst2.peerInfo.peerId, addrs: dst2.peerInfo.addrs)))
    await conn.writeLp(msg.buffer)
    rcv = RelayMessage.decode(await conn.readLp(1024))
    rcv.checkMsg(Opt.some(RelayType.Status), Opt.some(HopCantDialDst))
    await allFutures(dst2.stop())

  asyncTest "Dial Peer":
    let maStr = $srelay.peerInfo.addrs[0] & "/p2p/" & $srelay.peerInfo.peerId & "/p2p-circuit"
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
