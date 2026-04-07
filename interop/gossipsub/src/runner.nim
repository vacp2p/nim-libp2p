# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, stew/endians2, std/streams
import
  ../../../libp2p/[
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/pubsub,
    protocols/pubsub/rpc/messages,
    switch,
  ]
import ./[instructions, lib, logger]

type ScriptRunner* = ref object
  nodeId*: int
  node*: GossipSub
  logStream*: Stream
  resolveAddr*: proc(nodeId: int): MultiAddress {.gcsafe.}
  startTime: Moment

# Forward declaration
proc executeInstruction*(runner: ScriptRunner, instruction: ScriptInstruction) {.async.}

proc executeConnect(runner: ScriptRunner, connectTo: seq[int]) {.async.} =
  for targetId in connectTo:
    let targetPid = nodePeerId(targetId)
    try:
      let targetAddr = runner.resolveAddr(targetId)
      await runner.node.switch.connect(targetPid, @[targetAddr])
    except Exception as e:
      warn "Connect failed", target = targetId, error = e.msg

proc executeIfNodeIDEquals(
    runner: ScriptRunner, nodeID: int, inner: ScriptInstruction
) {.async.} =
  if nodeID == runner.nodeId:
    await runner.executeInstruction(inner)

proc executeWaitUntil(runner: ScriptRunner, elapsedSeconds: int) {.async.} =
  let target = runner.startTime + seconds(elapsedSeconds)
  let now = Moment.now()
  if target > now:
    await sleepAsync(target - now)

proc executeSubscribeToTopic(runner: ScriptRunner, topicId: string) {.async.} =
  let logStream = runner.logStream

  proc handler(topic: string, data: seq[byte]) {.async.} =
    if data.len >= 8:
      let msgId = extractMsgId(data)
      logReceivedMessage(logStream, $msgId, topic)

  runner.node.subscribe(topicId, handler)

proc executePublish(
    runner: ScriptRunner,
    publishTopicID: string,
    messageSizeBytes: int,
    publishMessageID: int,
) {.async.} =
  var data = newSeq[byte](messageSizeBytes)
  let msgIdU64 = uint64(publishMessageID)
  data[0 ..< 8] = toBytesBE(msgIdU64)
  try:
    discard await runner.node.publish(publishTopicID, data)
  except CatchableError as e:
    warn "Publish failed", messageID = publishMessageID, error = e.msg

proc executeSetTopicValidationDelay(
    runner: ScriptRunner, validationTopicID: string, delaySeconds: float64
) {.async.} =
  let delay = milliseconds(int64(delaySeconds * 1000.0))
  runner.node.addValidator(
    @[validationTopicID],
    proc(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
      await sleepAsync(delay)
      return ValidationResult.Accept,
  )

proc executeInstruction*(
    runner: ScriptRunner, instruction: ScriptInstruction
) {.async.} =
  case instruction.kind
  of InitGossipSub:
    discard # Node already initialized, params applied at creation time
  of Connect:
    await runner.executeConnect(instruction.connectTo)
  of IfNodeIDEquals:
    await runner.executeIfNodeIDEquals(instruction.nodeID, instruction.inner[])
  of WaitUntil:
    await runner.executeWaitUntil(instruction.elapsedSeconds)
  of SubscribeToTopic:
    await runner.executeSubscribeToTopic(instruction.topicID)
  of Publish:
    await runner.executePublish(
      instruction.publishTopicID, instruction.messageSizeBytes,
      instruction.publishMessageID,
    )
  of SetTopicValidationDelay:
    await runner.executeSetTopicValidationDelay(
      instruction.validationTopicID, instruction.delaySeconds
    )

proc runScript*(runner: ScriptRunner, instructions: seq[ScriptInstruction]) {.async.} =
  ## Execute a sequence of script instructions.
  runner.startTime = Moment.now()
  let pid = PeerId.init(nodePrivKey(runner.nodeId)).expect("valid peer id")
  logPeerId(runner.logStream, pid, runner.nodeId)

  for instr in instructions:
    await runner.executeInstruction(instr)
