# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, stew/endians2, std/streams
import
  ../../../libp2p/[
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/rpc/messages,
    switch,
  ]
import ./[instructions, node, logger]

logScope:
  topics = "gossipsub-interop"

type ScriptRunner* = ref object
  nodeId*: int
  node*: GossipSub
  logStream*: Stream
  resolveAddr*: proc(nodeId: int): MultiAddress {.gcsafe, raises: [CatchableError].}
  startTime: Moment

# Forward declaration
proc executeInstruction*(runner: ScriptRunner, instruction: ScriptInstruction) {.async.}

proc executeConnect(runner: ScriptRunner, connectTo: seq[int]) {.async.} =
  for targetId in connectTo:
    let targetPeerId = nodePeerId(targetId)
    try:
      let targetAddr = runner.resolveAddr(targetId)
      await runner.node.switch.connect(targetPeerId, @[targetAddr])
    except CancelledError as e:
      raise e
    except CatchableError as e:
      warn "Connect failed", target = targetId, error = e.msg

proc executeIfNodeIDEquals(
    runner: ScriptRunner, nodeID: int, inner: ScriptInstruction
) {.async.} =
  if nodeID == runner.nodeId:
    await runner.executeInstruction(inner)

proc executeWaitUntil(runner: ScriptRunner, elapsed: Duration) {.async.} =
  let targetTime = runner.startTime + elapsed
  let now = Moment.now()
  if now < targetTime:
    await sleepAsync(targetTime - now)

proc executeSubscribeToTopic(runner: ScriptRunner, topicId: string) {.async.} =
  let logStream = runner.logStream

  proc topicHandler(topic: string, data: seq[byte]) {.async.} =
    if data.len >= 8:
      let msgId = extractMsgId(data)
      logReceivedMessage(logStream, $msgId, topic)

  runner.node.subscribe(topicId, topicHandler)

proc executePublish(
    runner: ScriptRunner,
    publishTopicID: string,
    messageSizeBytes: int,
    publishMessageID: int,
) {.async.} =
  doAssert messageSizeBytes >= 8, "messageSizeBytes must be at least 8"
  var data = newSeq[byte](messageSizeBytes)
  let msgIdU64 = uint64(publishMessageID)
  data[0 ..< 8] = toBytesBE(msgIdU64)
  try:
    discard await runner.node.publish(publishTopicID, data)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "Publish failed", messageID = publishMessageID, error = e.msg

proc executeSetTopicValidationDelay(
    runner: ScriptRunner, validationTopicID: string, delay: Duration
) {.async.} =
  runner.node.addValidator(
    @[validationTopicID],
    proc(
        topic: string, message: messages.Message
    ): Future[ValidationResult] {.gcsafe, raises: [].} =
      let validationFut = newFuture[ValidationResult]("topicValidator")
      proc delayedAccept() {.async.} =
        try:
          await sleepAsync(delay)
          validationFut.complete(ValidationResult.Accept)
        except CancelledError:
          validationFut.complete(ValidationResult.Ignore)

      asyncSpawn delayedAccept()
      validationFut,
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
    await runner.executeWaitUntil(instruction.elapsed)
  of SubscribeToTopic:
    await runner.executeSubscribeToTopic(instruction.topicID)
  of Publish:
    await runner.executePublish(
      instruction.publishTopicID, instruction.messageSizeBytes,
      instruction.publishMessageID,
    )
  of SetTopicValidationDelay:
    await runner.executeSetTopicValidationDelay(
      instruction.validationTopicID, instruction.delay
    )

proc runScript*(runner: ScriptRunner, instructions: seq[ScriptInstruction]) {.async.} =
  ## Execute a sequence of script instructions.
  runner.startTime = Moment.now()
  let peerId = PeerId.init(nodePrivKey(runner.nodeId)).expect("valid peer id")
  logPeerId(runner.logStream, peerId, runner.nodeId)

  for instr in instructions:
    await runner.executeInstruction(instr)
