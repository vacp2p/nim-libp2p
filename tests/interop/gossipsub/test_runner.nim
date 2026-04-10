# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, streams, strutils
import
  ../../../libp2p/[
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/rpc/message,
    switch,
  ]
import
  ../../../interop/gossipsub/src/[node, instructions, runner, interop_partial_message]
import ../../tools/[unittest]

suite "GossipSub Interop - Script runner - Component":
  var node0, node1: GossipSub

  proc setupNodes(): Future[void] {.async.} =
    node0 = createNode(0, MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    node1 = createNode(1, MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    await node0.switch.start()
    await node1.switch.start()

  proc teardownNodes(): Future[void] {.async.} =
    await node0.switch.stop()
    await node1.switch.stop()

  proc getAddr(node: GossipSub): MultiAddress =
    node.switch.peerInfo.addrs[0]

  asyncTest "script runs connect + subscribe + publish":
    await setupNodes()
    defer:
      await teardownNodes()

    const topic = "foobar"
    let receivedMsgIdFut = newFuture[string]()
    let targetAddr = node1.getAddr()

    # Node 1: subscribe to receive messages
    node1.subscribe(
      topic,
      proc(topic: string, data: seq[byte]) {.async.} =
        if data.len >= 8 and not receivedMsgIdFut.finished():
          receivedMsgIdFut.complete($extractMsgId(data))
      ,
    )

    # Build a script for node 0
    let script =
      @[
        ScriptInstruction(kind: InitGossipSub, gossipSubParams: GossipSubParams.init()),
        ScriptInstruction(kind: Connect, connectTo: @[1]),
        ScriptInstruction(kind: SubscribeToTopic, topicID: topic, partial: false),
        ScriptInstruction(kind: WaitUntil, elapsed: 2.seconds),
        ScriptInstruction(
          kind: Publish,
          publishMessageID: 99,
          messageSizeBytes: 512,
          publishTopicID: topic,
        ),
        ScriptInstruction(
          kind: SetTopicValidationDelay,
          validationTopicID: topic,
          delay: 300.milliseconds,
        ),
      ]

    var stream = newStringStream()
    let runner = ScriptRunner(
      nodeId: 0,
      node: node0,
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner.runScript(script)

    check (await receivedMsgIdFut.wait(10.seconds)) == "99"

  asyncTest "ifNodeIDEquals filters correctly":
    await setupNodes()
    defer:
      await teardownNodes()

    let targetAddr = node1.getAddr()

    let inner = new ScriptInstruction
    inner[] = ScriptInstruction(kind: Connect, connectTo: @[1])

    let script =
      @[
        ScriptInstruction(kind: InitGossipSub, gossipSubParams: GossipSubParams.init()),
        # This should be skipped (node 5 != node 0)
        ScriptInstruction(kind: IfNodeIDEquals, nodeID: 5, inner: inner),
      ]

    var stream = newStringStream()
    let runner = ScriptRunner(
      nodeId: 0,
      node: node0,
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner.runScript(script)

    # Node 0 should not be connected
    check node0.switch.connectedPeers(Direction.Out).len == 0

    # Run with matching nodeID
    let script2 = @[ScriptInstruction(kind: IfNodeIDEquals, nodeID: 0, inner: inner)]

    let runner2 = ScriptRunner(
      nodeId: 0,
      node: node0,
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner2.runScript(script2)

    # Now should be connected
    check node0.switch.connectedPeers(Direction.Out).len == 1

  asyncTest "addPartialMessage logs 'All parts received' when bitmap is complete":
    let pmState = PartialMessageState(logStream: newStringStream())
    let node = createNode(0, MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    await node.switch.start()
    defer:
      await node.switch.stop()

    let runner = ScriptRunner(
      nodeId: 0,
      node: node,
      logStream: pmState.logStream,
      pmState: pmState,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    )

    let script =
      @[
        ScriptInstruction(kind: InitGossipSub, gossipSubParams: GossipSubParams.init()),
        ScriptInstruction(
          kind: AddPartialMessage,
          addTopicID: "test",
          groupID: 1'u64,
          partsBitmap: 0xFF'u8, # all parts
        ),
      ]

    await runner.runScript(script)

    let output = StringStream(pmState.logStream).data
    check output.contains("All parts received")
    check output.contains("\"group id\":\"1\"")

  asyncTest "addPartialMessage does NOT log when bitmap is partial":
    let pmState = PartialMessageState(logStream: newStringStream())
    let node = createNode(0, MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    await node.switch.start()
    defer:
      await node.switch.stop()

    let runner = ScriptRunner(
      nodeId: 0,
      node: node,
      logStream: pmState.logStream,
      pmState: pmState,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    )

    let script =
      @[
        ScriptInstruction(kind: InitGossipSub, gossipSubParams: GossipSubParams.init()),
        ScriptInstruction(
          kind: AddPartialMessage,
          addTopicID: "test",
          groupID: 1'u64,
          partsBitmap: 0b00001111'u8, # only 4 parts
        ),
      ]

    await runner.runScript(script)

    let output = StringStream(pmState.logStream).data
    check not output.contains("All parts received")

  asyncTest "two nodes exchange partial messages and both log 'All parts received'":
    # Node 0 has parts 0-3 (0x0F), Node 1 has parts 4-7 (0xF0)
    # After exchange, both should have all parts.
    let pmState0 = PartialMessageState(logStream: newStringStream())
    let pmState1 = PartialMessageState(logStream: newStringStream())

    let pmConfig0 = makePartialMessageConfig(pmState0)
    let pmConfig1 = makePartialMessageConfig(pmState1)

    let n0 = createNode(
      0,
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
      partialMessageConfig = Opt.some(pmConfig0),
    )
    let n1 = createNode(
      1,
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
      partialMessageConfig = Opt.some(pmConfig1),
    )

    pmState0.gossipsub = n0
    pmState1.gossipsub = n1

    await n0.switch.start()
    await n1.switch.start()
    defer:
      await n0.switch.stop()
      await n1.switch.stop()

    let addr1 = n1.switch.peerInfo.addrs[0]

    const topic = "a-subnet"
    const groupId = 42'u64

    # Connect first, then subscribe (to ensure subscription exchange happens correctly)
    await n0.switch.connect(nodePeerId(1), @[addr1])
    await sleepAsync(500.milliseconds) # let connection establish

    # Both subscribe with partial=true
    n0.subscribe(topic, nil, requestsPartial = true, supportsSendingPartial = true)
    n1.subscribe(topic, nil, requestsPartial = true, supportsSendingPartial = true)

    # Wait for mesh formation and extension negotiation
    await sleepAsync(3.seconds)

    # Node 0 adds parts 0-3
    let pm0 = newInteropPartialMessage(groupId)
    pm0.fillParts(0x0F)
    pmState0.messages[topic & ":" & $groupId] = pm0

    # Node 1 adds parts 4-7
    let pm1 = newInteropPartialMessage(groupId)
    pm1.fillParts(0xF0)
    pmState1.messages[topic & ":" & $groupId] = pm1

    # Node 0 publishes — sends metadata to node 1
    await n0.publishPartial(topic, pm0)
    await sleepAsync(1.seconds)

    # Node 1 publishes — sends metadata to node 0
    await n1.publishPartial(topic, pm1)
    await sleepAsync(1.seconds)

    # Second round of publishes to trigger data exchange
    # (now both sides know each other's metadata)
    await n0.publishPartial(topic, pm0)
    await n1.publishPartial(topic, pm1)
    await sleepAsync(3.seconds)

    let output0 = StringStream(pmState0.logStream).data
    let output1 = StringStream(pmState1.logStream).data

    check output0.contains("All parts received")
    check output1.contains("All parts received")
