{.used.}

import bearssl, chronos, options
import ../libp2p
import ../libp2p/[protocols/relayv2/relayv2,
                  protocols/relayv2/messages]
import ./helpers
import std/times

proc createSwitch(cl: Client): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelayV2(cl)
    .build()

suite "Circuit Relay V2":

  suite "Reservation":
    asyncTearDown:
      await allFutures(src1.stop(), src2.stop(), rel.stop())
      checkTrackers()
    var
      ttl {.threadvar.}: int
      ldur {.threadvar.}: uint32
      ldata {.threadvar.}: uint64
      cl1 {.threadvar.}: Client
      cl2 {.threadvar.}: Client
      src1 {.threadvar.}: Switch
      src2 {.threadvar.}: Switch
      rel {.threadvar.}: Switch
      rv2 {.threadvar.}: RelayV2
      rsvp {.threadvar.}: Rsvp
      range {.threadvar.}: HSlice[times.DateTime, times.DateTime]

    asyncSetup:
      ttl = 1
      ldur = 60
      ldata = 2048
      cl1 = Client.new()
      cl2 = Client.new()
      src1 = createSwitch(cl1)
      src2 = createSwitch(cl2)
      rel = newStandardSwitch()
      rv2 = RelayV2.new(rel,
                        reservationTTL=initDuration(seconds=ttl),
                        limitDuration=ldur,
                        limitData=ldata,
                        maxReservation=1)
      rel.mount(rv2)
      await rv2.start()
      await src1.start()
      await src2.start()
      await rel.start()
      await src1.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      await src2.connect(rel.peerInfo.peerId, rel.peerInfo.addrs)
      rsvp = await cl1.reserve(rel.peerInfo)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata

    asynctest "Too many reservations":
      let conn = await cl2.switch.dial(rel.peerInfo.peerId, rel.peerInfo.addrs, RelayV2HopCodec)
      let pb = encode(HopMessage(msgType: HopMessageType.Reserve))
      await conn.writeLp(pb.buffer)
      let msg = HopMessage.decode(await conn.readLp(MsgSize)).get()
      check:
        msg.msgType == HopMessageType.Status
        msg.status == some(Status.ReservationRefused)

    asynctest "Too many reservations + Reconnect":
      expect(ReservationError):
        discard await cl2.reserve(rel.peerInfo)
      await rel.disconnect(src1.peerInfo.peerId)
      rsvp = await cl2.reserve(rel.peerInfo)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata
    
    asynctest "Reservation ttl expires":
      await sleepAsync(chronos.timer.seconds(ttl + 1))
      rsvp = await cl1.reserve(rel.peerInfo)
      range = now().utc + (ttl-1).seconds..now().utc + (ttl+1).seconds
      check:
        rsvp.expire.int64.fromUnix.utc in range
        rsvp.limitDuration == ldur
        rsvp.limitData == ldata
