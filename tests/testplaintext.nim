# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import tables
import chronos, stew/byteutils
import chronicles
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
                  protocols/secure/plaintext,
                  protocols/secure/secure,
                  upgrademngrs/muxedupgrade,
                  connmanager]
import ./helpers

suite "Plain text":
  teardown:
    checkTrackers()

  asyncTest "e2e: handle write & read":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverPlainText = PlainText.new(serverPrivKey)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(server)

    proc acceptHandler() {.async.} =
      let conn = await transport1.accept()
      let sconn = await serverPlainText.secure(conn, false, Opt.none(PeerId))
      try:
        await sconn.writeLp("Hello 1!")
        await sconn.writeLp("Hello 2!")
      finally:
        await sconn.close()
        await conn.close()

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientPlainText = PlainText.new(clientPrivKey)
      conn = await transport2.dial(transport1.addrs[0])

    let sconn = await clientPlainText.secure(conn, true, Opt.some(serverInfo.peerId))

    discard await sconn.readLp(100)
    var msg = await sconn.readLp(100)

    await sconn.close()
    await conn.close()
    await acceptFut
    await transport1.stop()
    await transport2.stop()

    check string.fromBytes(msg) == "Hello 2!"

  asyncTest "e2e: wrong peerid":
    let
      server = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      serverPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      serverInfo = PeerInfo.new(serverPrivKey, server)
      serverPlainText = PlainText.new(serverPrivKey)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(server)

    proc acceptHandler() {.async.} =
      let conn = await transport1.accept()
      try:
        discard await serverPlainText.secure(conn, false, Opt.none(PeerId))
      finally:
        await conn.close()

    let
      acceptFut = acceptHandler()
      transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
      clientPrivKey = PrivateKey.random(ECDSA, rng[]).get()
      clientInfo = PeerInfo.new(clientPrivKey, transport1.addrs)
      clientPlainText = PlainText.new(clientPrivKey)
      conn = await transport2.dial(transport1.addrs[0])

    expect(CatchableError):
      discard await clientPlainText.secure(conn, true, Opt.some(clientInfo.peerId))

    await conn.close()
    await acceptFut
    await transport1.stop()
    await transport2.stop()
