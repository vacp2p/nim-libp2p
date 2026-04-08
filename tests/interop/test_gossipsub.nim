# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, json, stew/byteutils, streams
import
  ../../libp2p/[
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/rpc/message,
    switch,
  ]
import ../tools/[unittest]
import ../../interop/gossipsub/src/[node, instructions, runner]

suite "GossipSub Interop":
  const expectedPeerIds = [
    # Node 0
    "12D3KooWDpJ7As7BWAwRMfu1VU2WCqNjvq387JEYKDBj4kx6nXTN",
    # Node 1
    "12D3KooWPjceQrSwdWXPyLLeABRXmuqt69Rg3sBYbU1Nft9HyQ6X",
    # Node 2
    "12D3KooWH3uVF6wv47WnArKHk5p6cvgCJEb74UTmxztmQDc298L3",
    # Node 3
    "12D3KooWQYhTNQdmr3ArTeUHRYzFg94BKyTkoWBDWez9kSCVe2Xo",
    # Node 4
    "12D3KooWLJtG8fd2hkQzTn96MrLvThmnNQjTUFZwGEsLRz5EmSzc",
  ]

  test "nodePeerId matches Go implementation for node 0-4":
    for i in 0 ..< expectedPeerIds.len:
      let pid = nodePeerId(i)
      let expected = PeerId.init(expectedPeerIds[i]).get()
      check pid == expected

  test "message ID from big-endian u64":
    var data = newSeq[byte](1024)
    # Message ID 42: big-endian encoding
    data[7] = 42
    let msg = Message(data: data, topic: "foobar")
    let res = interopMsgIdProvider(msg)
    check:
      res.isOk
      string.fromBytes(res.get()) == "42"

  test "parse initGossipSub instruction":
    let j = parseJson("""{"type": "initGossipSub", "gossipSubParams": {"D": 6}}""")
    let instr = parseInstruction(j)
    check:
      instr.kind == InitGossipSub
      instr.gossipSubParams.d == 6

  test "parse connect instruction":
    let j = parseJson("""{"type": "connect", "connectTo": [1, 2, 3]}""")
    let instr = parseInstruction(j)
    check:
      instr.kind == Connect
      instr.connectTo == @[1, 2, 3]

  test "parse ifNodeIDEquals instruction":
    let j = parseJson(
      """{"type": "ifNodeIDEquals", "nodeID": 5, "instruction": {"type": "connect", "connectTo": [0]}}"""
    )
    let instr = parseInstruction(j)
    check:
      instr.kind == IfNodeIDEquals
      instr.nodeID == 5
      instr.inner.kind == Connect
      instr.inner.connectTo == @[0]

  test "parse waitUntil instruction":
    let j = parseJson("""{"type": "waitUntil", "elapsedSeconds": 30}""")
    let instr = parseInstruction(j)
    check:
      instr.kind == WaitUntil
      instr.elapsed == 30.seconds

  test "parse subscribeToTopic instruction":
    let j = parseJson("""{"type": "subscribeToTopic", "topicID": "foobar"}""")
    let instr = parseInstruction(j)
    check:
      instr.kind == SubscribeToTopic
      instr.topicID == "foobar"
      instr.partial == false

  test "parse subscribeToTopic with partial":
    let j = parseJson(
      """{"type": "subscribeToTopic", "topicID": "foobar", "partial": true}"""
    )
    let instr = parseInstruction(j)
    check:
      instr.kind == SubscribeToTopic
      instr.partial == true

  test "parse publish instruction":
    let j = parseJson(
      """{"type": "publish", "messageID": 7, "messageSizeBytes": 2048, "topicID": "test"}"""
    )
    let instr = parseInstruction(j)
    check:
      instr.kind == Publish
      instr.publishMessageID == 7
      instr.messageSizeBytes == 2048
      instr.publishTopicID == "test"

  test "parse full script":
    let j = parseJson(
      """{"script": [
      {"type": "initGossipSub", "gossipSubParams": {}},
      {"type": "waitUntil", "elapsedSeconds": 10},
      {"type": "subscribeToTopic", "topicID": "test"}
    ]}"""
    )
    let script = parseScript(j)
    check:
      script.len == 3
      script[0].kind == InitGossipSub
      script[1].kind == WaitUntil
      script[2].kind == SubscribeToTopic

  test "toGossipSubParams maps all fields and uses default for missing ones":
    let default = GossipSubParams.init()

    let empty = toGossipSubParams(parseJson("""{}"""))
    check:
      empty.d == default.d
      empty.heartbeatInterval == default.heartbeatInterval

    let params = toGossipSubParams(
      parseJson(
        """{
        "D": 8, "Dlo": 5, "Dhi": 14,
        "HeartbeatInterval": 2000000000,
        "FanoutTTL": 60000000000,
        "PruneBackoff": 30000000000,
        "UnsubscribeBackoff": 10000000000,
        "HistoryLength": 10,
        "HistoryGossip": 5,
        "Dlazy": 8,
        "GossipFactor": 0.5
      }"""
      )
    )
    check:
      params.d == 8
      params.dLow == 5
      params.dHigh == 14
      params.heartbeatInterval == 2.seconds
      params.fanoutTTL == 1.minutes
      params.pruneBackoff == 30.seconds
      params.unsubscribeBackoff == 10.seconds
      params.historyLength == 10
      params.historyGossip == 5
      params.dLazy == 8
      params.gossipFactor == 0.5

suite "GossipSub Interop - Script runner":
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
