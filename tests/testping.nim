{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../libp2p/[protocols/ping,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
                  transports/transport,
                  transports/tcptransport,
                  crypto/crypto,
                  upgrademngrs/upgrade]
import ./helpers

suite "Ping":
  var
    ma {.threadvar.}: MultiAddress
    serverFut {.threadvar.}: Future[void]
    acceptFut {.threadvar.}: Future[void]
    pingProto1 {.threadvar.}: Ping
    pingProto2 {.threadvar.}: Ping
    transport1 {.threadvar.}: Transport
    transport2 {.threadvar.}: Transport
    msListen {.threadvar.}: MultistreamSelect
    msDial {.threadvar.}: MultistreamSelect
    conn {.threadvar.}: Connection
    pingReceivedCount {.threadvar.}: int

  asyncSetup:
    ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

    transport1 = TcpTransport.new(upgrade = Upgrade())
    transport2 = TcpTransport.new(upgrade = Upgrade())

    proc handlePing(peer: PeerId) {.async, closure.} =
      inc pingReceivedCount
    pingProto1 = Ping.new()
    pingProto2 = Ping.new(handlePing)

    msListen = MultistreamSelect.new()
    msDial = MultistreamSelect.new()

    pingReceivedCount = 0

  asyncTeardown:
    await conn.close()
    await acceptFut
    await transport1.stop()
    await serverFut
    await transport2.stop()
    checkTrackers()

  asyncTest "simple ping":
    msListen.addHandler(PingCodec, pingProto1)
    serverFut = transport1.start(@[ma])
    proc acceptHandler(): Future[void] {.async.} =
      let c = await transport1.accept()
      await msListen.handle(c)

    acceptFut = acceptHandler()
    conn = await transport2.dial(transport1.addrs[0])

    discard await msDial.select(conn, PingCodec)
    let time = await pingProto2.ping(conn)

    check not time.isZero()

  asyncTest "ping callback":
    msDial.addHandler(PingCodec, pingProto2)
    serverFut = transport1.start(@[ma])
    proc acceptHandler(): Future[void] {.async.} =
      let c = await transport1.accept()
      discard await msListen.select(c, PingCodec)
      discard await pingProto1.ping(c)

    acceptFut = acceptHandler()
    conn = await transport2.dial(transport1.addrs[0])

    await msDial.handle(conn)
    check pingReceivedCount == 1

  asyncTest "bad ping data ack":
    type FakePing = ref object of LPProtocol
    let fakePingProto = FakePing()
    proc fakeHandle(conn: Connection, proto: string) {.async, closure.} =
      var
        buf: array[32, byte]
        fakebuf: array[32, byte]
      await conn.readExactly(addr buf[0], 32)
      await conn.write(@fakebuf)
    fakePingProto.codec = PingCodec
    fakePingProto.handler = fakeHandle

    msListen.addHandler(PingCodec, fakePingProto)
    serverFut = transport1.start(@[ma])
    proc acceptHandler(): Future[void] {.async.} =
      let c = await transport1.accept()
      await msListen.handle(c)

    acceptFut = acceptHandler()
    conn = await transport2.dial(transport1.addrs[0])

    discard await msDial.select(conn, PingCodec)
    let p = pingProto2.ping(conn)
    var raised = false
    try:
      discard await p
      check false #should have raised
    except WrongPingAckError:
      raised = true
    check raised
