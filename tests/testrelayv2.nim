{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import bearssl, chronos, options
import ../libp2p
import ../libp2p/[protocols/connectivity/relay/relay,
                  protocols/connectivity/relay/messages,
                  protocols/connectivity/relay/utils,
                  protocols/connectivity/relay/client]
import ./helpers
import std/times
import stew/byteutils

proc createSwitch(r: Relay = nil, useYamux: bool = false): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()

  if useYamux:
    builder = builder.withYamux()
  else:
    builder = builder.withMplex()

  if r != nil:
    builder = builder.withCircuitRelay(r)

  return builder
    .withNoise()
    .build()

suite "Circuit Relay V2":

  suite "Reservation":
    asyncTeardown:
      await allFutures(src1.stop(), src2.stop(), rel.stop())
      checkTrackers()
    var
      ttl {.threadvar.}: int
      ldur {.threadvar.}: uint32
      ldata {.threadvar.}: uint64
      cl1 {.threadvar.}: RelayClient
      cl2 {.threadvar.}: RelayClient
      rv2 {.threadvar.}: Relay
      src1 {.threadvar.}: Switch
      src2 {.threadvar.}: Switch
      rel {.threadvar.}: Switch
      rsvp {.threadvar.}: Rsvp
      range {.threadvar.}: HSlice[times.DateTime, times.DateTime]

    asyncSetup:
      ttl = 3
      ldur = 60
      ldata = 2048
      cl1 = RelayClient.new()
      cl2 = RelayClient.new()
      rv2 = Relay.new(reservationTTL=initDuration(seconds=ttl),
                      limitDuration=ldur,
                      limitData=ldata,
                      maxCircuit=1)
      src1 = createSwitch(cl1)
      src2 = createSwitch(cl2)
      rel = createSwitch(rv2)

      await src1.start()
      await src2.start()
      await rel.start()
      await src1.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await src2.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      rsvp = await cl1.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-3).seconds..now().utc + (ttl+3).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asyncTest "Too many reservations":
      let conn = await cl2.switch.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayV2HopCodec)
      let pb = encode(HopMessage(msgType: HopMessageType.Reserve))
      await conn.writeLp(pb.buffer)
      let msg = HopMessage.decode(await conn.readLp(RelayMsgSize)).get()
      check:
        msg.msgType == HopMessageType.Status
        msg.status == Opt.some(StatusV2.ReservationRefused)

    asyncTest "Too many reservations + Reconnect":
      expect(ReservationError):
        discard await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await rel.disconnect(src1.peerInfo.peerId)
      rsvp = await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-3).seconds..now().utc + (ttl+3).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asyncTest "Reservation ttl expires":
      await sleepAsync(chronos.timer.seconds(ttl + 1))
      rsvp = await cl1.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-3).seconds..now().utc + (ttl+3).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asyncTest "Reservation over relay":
      let
        rv2add = Relay.new()
        addrs = @[ MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                     $rel.peerInfo.peerId & "/p2p-circuit").get() ]
      rv2add.setup(src2)
      await rv2add.start()
      src2.mount(rv2add)
      rv2.maxCircuit.inc()

      rsvp = await cl2.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
      range = now().utc + (ttl-3).seconds..now().utc + (ttl+3).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata
      expect(ReservationError):
        discard await cl1.reserve(src2.peerInfo.peerId, addrs)

  for (useYamux, muxName) in [(false, "Mplex"), (true, "Yamux")]:
    suite "Circuit Relay V2 Connection using " & muxName:
      asyncTeardown:
        checkTrackers()
      var
        customProtoCodec {.threadvar.}: string
        proto {.threadvar.}: LPProtocol
        ttl {.threadvar.}: int
        ldur {.threadvar.}: uint32
        ldata {.threadvar.}: uint64
        srcCl {.threadvar.}: RelayClient
        dstCl {.threadvar.}: RelayClient
        rv2 {.threadvar.}: Relay
        src {.threadvar.}: Switch
        dst {.threadvar.}: Switch
        rel {.threadvar.}: Switch
        rsvp {.threadvar.}: Rsvp
        conn {.threadvar.}: Connection

      asyncSetup:
        customProtoCodec = "/test"
        proto = new LPProtocol
        proto.codec = customProtoCodec
        ttl = 60
        ldur = 120
        ldata = 16384
        srcCl = RelayClient.new()
        dstCl = RelayClient.new()
        src = createSwitch(srcCl, useYamux)
        dst = createSwitch(dstCl, useYamux)
        rel = createSwitch(nil, useYamux)

      asyncTest "Connection succeed":
        proto.handler = proc(conn: Connection, proto: string) {.async.} =
          check: "test1" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("test2")
          check: "test3" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("test4")
          await conn.close()
        rv2 = Relay.new(reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
        rv2.setup(rel)
        rel.mount(rv2)
        dst.mount(proto)

        await rel.start()
        await src.start()
        await dst.start()

        let addrs = MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                  $rel.peerInfo.peerId & "/p2p-circuit").get()

        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

        rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)

        conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
        await conn.writeLp("test1")
        check: "test2" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test3")
        check: "test4" == string.fromBytes(await conn.readLp(1024))
        await allFutures(conn.close())
        await allFutures(src.stop(), dst.stop(), rel.stop())

      asyncTest "Connection duration exceeded":
        ldur = 3
        proto.handler = proc(conn: Connection, proto: string) {.async.} =
          check "wanna sleep?" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("yeah!")
          check "go!" == string.fromBytes(await conn.readLp(1024))
          await sleepAsync(chronos.timer.seconds(ldur + 1))
          await conn.writeLp("that was a cool power nap")
          await conn.close()
        rv2 = Relay.new(reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
        rv2.setup(rel)
        rel.mount(rv2)
        dst.mount(proto)

        await rel.start()
        await src.start()
        await dst.start()

        let addrs = MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                  $rel.peerInfo.peerId & "/p2p-circuit").get()

        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

        rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
        conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
        await conn.writeLp("wanna sleep?")
        check: "yeah!" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("go!")
        expect(LPStreamEOFError):
          discard await conn.readLp(1024)
        await allFutures(conn.close())
        await allFutures(src.stop(), dst.stop(), rel.stop())

      asyncTest "Connection data exceeded":
        ldata = 1000
        proto.handler = proc(conn: Connection, proto: string) {.async.} =
          check "count me the better story you know" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("do you expect a lorem ipsum or...?")
          check "surprise me!" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("""Call me Ishmael. Some years ago--never mind how long
  precisely--having little or no money in my purse, and nothing
  particular to interest me on shore, I thought I would sail about a
  little and see the watery part of the world. It is a way I have of
  driving off the spleen and regulating the circulation. Whenever I
  find myself growing grim about the mouth; whenever it is a damp,
  drizzly November in my soul; whenever I find myself involuntarily
  pausing before coffin warehouses, and bringing up the rear of every
  funeral I meet; and especially whenever my hypos get such an upper
  hand of me, that it requires a strong moral principle to prevent me
  from deliberately stepping into the street, and methodically knocking
  people's hats off--then, I account it high time to get to sea as soon
  as I can. This is my substitute for pistol and ball. With a
  philosophical flourish Cato throws himself upon his sword; I quietly
  take to the ship.""")
        rv2 = Relay.new(reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
        rv2.setup(rel)
        rel.mount(rv2)
        dst.mount(proto)

        await rel.start()
        await src.start()
        await dst.start()

        let addrs = MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                  $rel.peerInfo.peerId & "/p2p-circuit").get()

        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

        rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
        conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
        await conn.writeLp("count me the better story you know")
        check: "do you expect a lorem ipsum or...?" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("surprise me!")
        expect(LPStreamEOFError):
          discard await conn.readLp(1024)
        await allFutures(conn.close())
        await allFutures(src.stop(), dst.stop(), rel.stop())

      asyncTest "Reservation ttl expire during connection":
        ttl = 3
        proto.handler = proc(conn: Connection, proto: string) {.async.} =
          check: "test1" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("test2")
          check: "test3" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("test4")
          await conn.close()
        rv2 = Relay.new(reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata)
        rv2.setup(rel)
        rel.mount(rv2)
        dst.mount(proto)

        await rel.start()
        await src.start()
        await dst.start()

        let addrs = MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                  $rel.peerInfo.peerId & "/p2p-circuit").get()

        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await dst.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)

        rsvp = await dstCl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
        conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
        await conn.writeLp("test1")
        check: "test2" == string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("test3")
        check: "test4" == string.fromBytes(await conn.readLp(1024))
        await src.disconnect(rel.peerInfo.peerId)
        await sleepAsync(chronos.timer.seconds(ttl + 1))

        expect(DialFailedError):
          await conn.close()
          await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
          conn = await src.dial(dst.peerInfo.peerId, @[ addrs ], customProtoCodec)
        await allFutures(conn.close())
        await allFutures(src.stop(), dst.stop(), rel.stop())

      asyncTest "Connection over relay":
        # src => rel => rel2 => dst
        # rel2 reserve rel
        # dst reserve rel2
        # src try to connect with dst
        proto.handler = proc(conn: Connection, proto: string) {.async.} =
          raise newException(CatchableError, "Should not be here")
        let
          rel2Cl = RelayClient.new(canHop = true)
          rel2 = createSwitch(rel2Cl, useYamux)
          rv2 = Relay.new()
        rv2.setup(rel)
        rel.mount(rv2)
        dst.mount(proto)
        await rel.start()
        await rel2.start()
        await src.start()
        await dst.start()

        let
          addrs = @[ MultiAddress.init($rel.peerInfo.addrs[0] & "/p2p/" &
                                       $rel.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                       $rel2.peerInfo.peerId & "/p2p/" &
                                       $rel2.peerInfo.peerId & "/p2p-circuit").get() ]

        await src.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await rel2.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
        await dst.connect(rel2.peerInfo.peerId, rel2.peerInfo.addrs)

        rsvp = await rel2Cl.reserve(rel.peerInfo.peerId, rel.peerInfo.addrs)
        let rsvp2 = await dstCl.reserve(rel2.peerInfo.peerId, rel2.peerInfo.addrs)

        expect(DialFailedError):
          conn = await src.dial(dst.peerInfo.peerId, addrs, customProtoCodec)
        if not conn.isNil():
          await allFutures(conn.close())
        await allFutures(src.stop(), dst.stop(), rel.stop(), rel2.stop())

      asyncTest "Connection using ClientRelay":
        var
          protoABC = new LPProtocol
          protoBCA = new LPProtocol
          protoCAB = new LPProtocol
        protoABC.codec = "/abctest"
        protoABC.handler = proc(conn: Connection, proto: string) {.async.} =
          check: "testABC1" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testABC2")
          check: "testABC3" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testABC4")
          await conn.close()
        protoBCA.codec = "/bcatest"
        protoBCA.handler = proc(conn: Connection, proto: string) {.async.} =
          check: "testBCA1" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testBCA2")
          check: "testBCA3" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testBCA4")
          await conn.close()
        protoCAB.codec = "/cabtest"
        protoCAB.handler = proc(conn: Connection, proto: string) {.async.} =
          check: "testCAB1" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testCAB2")
          check: "testCAB3" == string.fromBytes(await conn.readLp(1024))
          await conn.writeLp("testCAB4")
          await conn.close()

        let
          clientA = RelayClient.new(canHop = true)
          clientB = RelayClient.new(canHop = true)
          clientC = RelayClient.new(canHop = true)
          switchA = createSwitch(clientA, useYamux)
          switchB = createSwitch(clientB, useYamux)
          switchC = createSwitch(clientC, useYamux)

        switchA.mount(protoBCA)
        switchB.mount(protoCAB)
        switchC.mount(protoABC)

        await switchA.start()
        await switchB.start()
        await switchC.start()

        let
          addrsABC = MultiAddress.init($switchB.peerInfo.addrs[0] & "/p2p/" &
                                       $switchB.peerInfo.peerId & "/p2p-circuit").get()
          addrsBCA = MultiAddress.init($switchC.peerInfo.addrs[0] & "/p2p/" &
                                       $switchC.peerInfo.peerId & "/p2p-circuit").get()
          addrsCAB = MultiAddress.init($switchA.peerInfo.addrs[0] & "/p2p/" &
                                       $switchA.peerInfo.peerId & "/p2p-circuit").get()

        await switchA.connect(switchB.peerInfo.peerId, switchB.peerInfo.addrs)
        await switchB.connect(switchC.peerInfo.peerId, switchC.peerInfo.addrs)
        await switchC.connect(switchA.peerInfo.peerId, switchA.peerInfo.addrs)
        let rsvpABC = await clientA.reserve(switchC.peerInfo.peerId, switchC.peerInfo.addrs)
        let rsvpBCA = await clientB.reserve(switchA.peerInfo.peerId, switchA.peerInfo.addrs)
        let rsvpCAB = await clientC.reserve(switchB.peerInfo.peerId, switchB.peerInfo.addrs)
        let connABC = await switchA.dial(switchC.peerInfo.peerId, @[ addrsABC ], "/abctest")
        let connBCA = await switchB.dial(switchA.peerInfo.peerId, @[ addrsBCA ], "/bcatest")
        let connCAB = await switchC.dial(switchB.peerInfo.peerId, @[ addrsCAB ], "/cabtest")

        await connABC.writeLp("testABC1")
        await connBCA.writeLp("testBCA1")
        await connCAB.writeLp("testCAB1")
        check:
          "testABC2" == string.fromBytes(await connABC.readLp(1024))
          "testBCA2" == string.fromBytes(await connBCA.readLp(1024))
          "testCAB2" == string.fromBytes(await connCAB.readLp(1024))
        await connABC.writeLp("testABC3")
        await connBCA.writeLp("testBCA3")
        await connCAB.writeLp("testCAB3")
        check:
          "testABC4" == string.fromBytes(await connABC.readLp(1024))
          "testBCA4" == string.fromBytes(await connBCA.readLp(1024))
          "testCAB4" == string.fromBytes(await connCAB.readLp(1024))
        await allFutures(connABC.close(), connBCA.close(), connCAB.close())
        await allFutures(switchA.stop(), switchB.stop(), switchC.stop())
