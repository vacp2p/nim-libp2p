# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, streams, sequtils, strutils
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

proc setupNodes(count: int): Future[seq[GossipSub]] {.async.} =
  var nodes: seq[GossipSub]

  for i in 0 ..< count:
    let node = createNode(i, MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    nodes.add(node)

  await allFutures(nodes.mapIt(it.switch.start()))
  nodes

proc teardownNodes(nodes: seq[GossipSub]) {.async.} =
  await allFutures(nodes.mapIt(it.switch.stop()))

proc getAddr(node: GossipSub): MultiAddress =
  node.switch.peerInfo.addrs[0]

suite "GossipSub Interop - Script runner - Component":
  asyncTest "script runs connect + subscribe + publish":
    let nodes = await setupNodes(2)
    defer:
      await teardownNodes(nodes)

    const topic = "foobar"
    let receivedMsgIdFut = newFuture[string]()
    let targetAddr = nodes[1].getAddr()

    # Node 1: subscribe to receive messages
    nodes[1].subscribe(
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
      node: nodes[0],
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner.runScript(script)

    check (await receivedMsgIdFut.wait(10.seconds)) == "99"

  asyncTest "ifNodeIDEquals filters correctly":
    let nodes = await setupNodes(2)
    defer:
      await teardownNodes(nodes)

    let targetAddr = nodes[1].getAddr()

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
      node: nodes[0],
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner.runScript(script)

    # Node 0 should not be connected
    check nodes[0].switch.connectedPeers(Direction.Out).len == 0

    # Run with matching nodeID
    let script2 = @[ScriptInstruction(kind: IfNodeIDEquals, nodeID: 0, inner: inner)]

    let runner2 = ScriptRunner(
      nodeId: 0,
      node: nodes[0],
      logStream: stream,
      resolveAddr: proc(id: int): MultiAddress {.gcsafe.} =
        return targetAddr,
    )

    await runner2.runScript(script2)

    # Now should be connected
    check nodes[0].switch.connectedPeers(Direction.Out).len == 1

  asyncTest "two nodes exchange partial messages and both log 'All parts received'":
    # Node 0 has parts 0-3 (0x0F), Node 1 has parts 4-7 (0xF0)
    # After exchange, both should have all parts.

    # Create runners first (with nil node), build configs from them
    let logStream0 = newStringStream()
    let logStream1 = newStringStream()
    let runner0 = ScriptRunner(nodeId: 0, logStream: logStream0)
    let runner1 = ScriptRunner(nodeId: 1, logStream: logStream1)

    let n0 = createNode(
      0,
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
      partialMessageConfig = Opt.some(runner0.makePartialMessageConfig()),
    )
    let n1 = createNode(
      1,
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
      partialMessageConfig = Opt.some(runner1.makePartialMessageConfig()),
    )

    await allFutures(@[n0, n1].mapIt(it.switch.start()))
    defer:
      await allFutures(@[n0, n1].mapIt(it.switch.stop()))

    # Update runners after nodes are created and started
    runner0.node = n0
    runner1.node = n1
    runner1.resolveAddr = proc(id: int): MultiAddress {.gcsafe.} =
      n0.getAddr()

    const topic = "foobar"
    const groupId = 42'u64
    let key = makeKey(topic, groupId)

    # Build a script for node 0
    let script =
      @[
        ScriptInstruction(kind: InitGossipSub, gossipSubParams: GossipSubParams.init()),
        ScriptInstruction(kind: Connect, connectTo: @[0]),
        ScriptInstruction(kind: WaitUntil, elapsed: 1.seconds),
        ScriptInstruction(kind: SubscribeToTopic, topicID: topic, partial: true),
        ScriptInstruction(kind: WaitUntil, elapsed: 5.seconds),
        ScriptInstruction(
          kind: AddPartialMessage,
          addTopicID: topic,
          groupID: groupId,
          partsBitmap: 0xF0,
        ),
        ScriptInstruction(
          kind: PublishPartial,
          publishPartialTopicID: topic,
          publishPartialGroupID: groupId,
          publishToNodeIDs: @[0],
        ),
      ]

    await runner1.runScript(script)

    # Node 0 subscribes to the topic and adds partial message
    n0.subscribe(topic, nil, requestsPartial = true, supportsSendingPartial = true)

    # Node 0 adds parts 0-3
    let pm0 = newInteropPartialMessage(groupId)
    pm0.fillParts(0x0F)
    runner0.messages[key] = pm0

    # Assert both nodes receive full messages
    checkUntilTimeout:
      runner0.messages[key].isComplete()
      runner1.messages[key].isComplete()

    let output0 = logStream0.data
    let output1 = logStream1.data

    check:
      output0.contains("All parts received")
      output1.contains("All parts received")
