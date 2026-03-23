# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import algorithm, chronos, results, stew/byteutils, sequtils, tables
import
  ../../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/delay_strategy,
    protocols/ping,
    peerid,
    switch,
    builders,
  ]

import ../../../tools/[lifecycle, unittest]
import ../utils

suite "Mix Protocol - Message Delivery":
  asyncTeardown:
    checkTrackers()

  asyncTest "expect reply, exit != destination":
    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )
    startAndDeferStop(nodes)

    let (destNode, pingProto) = await setupDestNode(Ping.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        destNode.toMixDestination(),
        pingProto.codec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let response = await pingProto.ping(conn)
    await conn.close()

    check response != 0.seconds

  asyncTest "expect no reply, exit != destination":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )

    let data = @[1.byte, 2, 3, 4, 5]
    await conn.writeLp(data)
    await conn.close()

    let receivedMsg = await nrProto.receivedMessages.get().wait(2.seconds)
    check data == receivedMsg.data

    # assert anonymity of the sender
    let sender = nodes[0].switch.peerInfo.peerId
    let destination = destNode.peerInfo.peerId
    check:
      receivedMsg.connPeerId != sender
      receivedMsg.connPeerId != destination
      receivedMsg.connPeerId in nodes.mapIt(it.switch.peerInfo.peerId)

  asyncTest "multiple sequential messages on same connection":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )
    defer:
      await conn.close()

    let messages = (0 ..< 10).mapIt(newSeqWith(5, it.byte))

    for msg in messages:
      await conn.writeLp(msg)

    var received: seq[seq[byte]]
    for _ in messages:
      let msg = await nrProto.receivedMessages.get().wait(2.seconds)
      received.add(msg.data)

    check received.sorted == messages

  asyncTest "path nodes are random - exit node varies across messages":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    # Send multiple messages and track which mix node delivered each one
    const numMessages = 20
    var exitNodes: Table[PeerId, int]

    for i in 0 ..< numMessages:
      let conn = nodes[0]
        .toConnection(destNode.toMixDestination(), nrProto.codec)
        .expect("could not build connection")

      await conn.writeLp(@[byte(i)])
      await conn.close()

      let receivedMsg = await nrProto.receivedMessages.get().wait(2.seconds)
      exitNodes.mgetOrPut(receivedMsg.connPeerId, 0).inc()

    # With 20 messages and 9 eligible nodes,
    # random selection must produce at least 3 distinct exit nodes.
    # Sender must never be exit and destination must never be exit.
    let sender = nodes[0].switch.peerInfo.peerId
    let destination = destNode.peerInfo.peerId
    check:
      exitNodes.len >= 3
      sender notin exitNodes
      destination notin exitNodes

  when defined(libp2p_mix_experimental_exit_is_dest):
    asyncTest "expect reply, exit == destination":
      let nodes = await setupMixNodes(
        10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
      )

      let destNode = nodes[^1]
      let pingProto = Ping.new()
      destNode.switch.mount(pingProto)

      startAndDeferStop(nodes)

      let conn = nodes[0]
        .toConnection(
          MixDestination.exitNode(destNode.switch.peerInfo.peerId),
          pingProto.codec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
        )
        .expect("could not build connection")

      let response = await pingProto.ping(conn)
      await conn.close()

      check response != 0.seconds

  asyncTest "length-prefixed protocol - verify readLp fix":
    ## This test verifies the fix for the length prefix bug where responses
    ## from protocols using readLp() were losing their length prefix when
    ## flowing back through the mix network.
    let testPayload = "Privacy for everyone and transparency for people in power is one way to reduce corruption".toBytes()
    let echoProto = EchoProtocol.new()

    let nodes = await setupMixNodes(
      10,
      destReadBehavior =
        Opt.some((codec: echoProto.codec, callback: readLp(EchoMaxReadLen))),
    )

    let destNode = nodes[^1]
    destNode.switch.mount(echoProto)

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        destNode.toMixDestination(),
        echoProto.codec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    await conn.writeLp(testPayload)

    # Read response - this should work correctly with the length prefix fix
    let response = await conn.readLp(EchoMaxReadLen)
    await conn.close()

    check response == testPayload

  asyncTest "intermediate nodes apply delay":
    let delayMs: uint16 = 300
    let delayStrategy: DelayStrategy = FixedDelayStrategy(delayMs: delayMs)
    let nodes = await setupMixNodes(10, delayStrategy = Opt.some(delayStrategy))
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )
    defer:
      await conn.close()

    let startTime = Moment.now()
    let data = @[1.byte, 2, 3, 4, 5]
    await conn.writeLp(data)

    let receivedMsg = await nrProto.receivedMessages.get().wait(2.seconds)
    let elapsed = Moment.now() - startTime

    # Path == 3, 2 intermediate hops apply delay, exit node does not.
    check:
      receivedMsg.data == data
      elapsed >= milliseconds(int64(delayMs) * 2)

  asyncTest "concurrent messages with SURB replies":
    let echoProto = EchoProtocol.new()

    let nodes = await setupMixNodes(
      10,
      destReadBehavior =
        Opt.some((codec: echoProto.codec, callback: readLp(EchoMaxReadLen))),
    )
    startAndDeferStop(nodes)

    let (destNode, _) = await setupDestNode(echoProto)
    defer:
      await stopDestNode(destNode)

    proc sendAndReceive(
        node: MixProtocol, dest: MixDestination, data: seq[byte]
    ): Future[seq[byte]] {.async.} =
      let conn = node
        .toConnection(
          dest,
          echoProto.codec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
        )
        .expect("could not build connection")
      await conn.writeLp(data)
      let response = await conn.readLp(EchoMaxReadLen)
      await conn.close()
      return response

    # Send concurrent echo requests with unique payload from different nodes
    const numConcurrent = 5
    var futs: seq[Future[seq[byte]]]

    for i in 0 ..< numConcurrent:
      let payload = newSeqWith(4, i.byte)
      futs.add(sendAndReceive(nodes[i], destNode.toMixDestination(), payload))

    let responses = await allFinished(futs)

    # Every sender must receive exactly their own payload back
    for i, fut in responses:
      let expected = newSeqWith(4, i.byte)
      check:
        fut.completed()
        fut.value() == expected
