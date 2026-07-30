# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, sequtils
import
  ../../../libp2p/[protocols/kademlia, protocols/protocol, switch, builders],
  ../../../libp2p/stream/connection
import ../../tools/[crypto, lifecycle, multiaddress, switch_builder, unittest]

const
  TestCodec = "/test/kad-message-sender/1.0.0"
  MaxTestMsgSize = 4096

type CountingEcho = ref object of LPProtocol
  streams: int ## inbound streams the remote opened
  messages: int ## messages received across all of them
  reply: bool
  closeAfter: int ## close the stream once this many messages arrived; 0 keeps it open

proc newCountingEcho(reply = true, closeAfter = 0): CountingEcho =
  let echoProto = CountingEcho(reply: reply, closeAfter: closeAfter)
  echoProto.codec = TestCodec
  echoProto.handler = proc(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    echoProto.streams.inc()
    defer:
      await stream.close()

    while not stream.atEof:
      let buf =
        try:
          await stream.readLp(MaxTestMsgSize)
        except LPStreamError:
          return
      echoProto.messages.inc()

      if echoProto.reply:
        try:
          await stream.writeLp(buf)
        except LPStreamError:
          return

      if echoProto.closeAfter > 0 and echoProto.messages >= echoProto.closeAfter:
        return

  echoProto

proc setupPair(
    proto: CountingEcho
): tuple[client: Switch, server: Switch] {.raises: [LPError].} =
  let client = makeStandardSwitch(TcpAutoAddress)
  let server = makeStandardSwitch(TcpAutoAddress)
  server.mount(proto)
  (client, server)

suite "KadDHT message sender":
  teardown:
    checkTrackers()

  asyncTest "reuses a single stream across RPCs to the same peer":
    let proto = newCountingEcho()
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    for i in 0 ..< 3:
      let reply = await sender.sendRequest(
        server.peerInfo.peerId, server.peerInfo.addrs, @[byte i], 1.seconds
      )
      check reply.tryGet() == @[byte i]

    check:
      proto.streams == 1
      proto.messages == 3

  asyncTest "reopens transparently after the remote drops the stream":
    let proto = newCountingEcho(closeAfter = 1)
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    for i in 0 ..< 2:
      let reply = await sender.sendRequest(
        server.peerInfo.peerId, server.peerInfo.addrs, @[byte i], 1.seconds
      )
      check reply.tryGet() == @[byte i]

    check proto.streams == 2

  asyncTest "serializes concurrent RPCs on one stream":
    let proto = newCountingEcho()
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    let replies = (0 ..< 4).mapIt(
      sender.sendRequest(
        server.peerInfo.peerId, server.peerInfo.addrs, @[byte it], 5.seconds
      )
    )
    await allFutures(replies)

    # Each RPC reads back its own payload, so no reply was mistaken for another.
    for i, fut in replies:
      check fut.read().tryGet() == @[byte i]
    check proto.streams == 1

  asyncTest "a reply-less send retires its stream":
    let proto = newCountingEcho(reply = false)
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    for i in 0 ..< 2:
      check (
        await sender.sendMessage(
          server.peerInfo.peerId, server.peerInfo.addrs, @[byte i], 1.seconds
        )
      ).isOk()

    # A remote that does answer would leave its reply buffered, so a
    # fire-and-forget send must never hand its stream to the next RPC.
    checkUntilTimeout:
      proto.streams == 2
      proto.messages == 2

  asyncTest "an unanswered request fails at the read stage":
    let proto = newCountingEcho(reply = false)
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    let reply = await sender.sendRequest(
      server.peerInfo.peerId, server.peerInfo.addrs, @[byte 1], 100.milliseconds
    )
    check:
      reply.isErr()
      reply.error().stage == readStage

  asyncTest "an unreachable peer fails at the dial stage":
    let client = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[client])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    let unreachable = PeerId.random(rng()).tryGet()
    let reply = await sender.sendRequest(
      unreachable,
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()],
      @[byte 1],
      1.seconds,
    )
    check:
      reply.isErr()
      reply.error().stage == dialStage

  asyncTest "dropPeer forces the next RPC onto a fresh stream":
    let proto = newCountingEcho()
    let (client, server) = setupPair(proto)
    startAndDeferStop(@[client, server])

    let sender = MessageSender.new(client, TestCodec, MaxTestMsgSize)
    defer:
      await sender.stop()

    check (
      await sender.sendRequest(
        server.peerInfo.peerId, server.peerInfo.addrs, @[byte 1], 1.seconds
      )
    ).isOk()

    await sender.dropPeer(server.peerInfo.peerId)

    check (
      await sender.sendRequest(
        server.peerInfo.peerId, server.peerInfo.addrs, @[byte 2], 1.seconds
      )
    ).isOk()
    check proto.streams == 2
