# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results, stew/endians2, streams, tables
import
  ../../../libp2p/[
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/gossipsub/extension_partial_message,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/rpc/messages,
    switch,
    utils/tablekey,
  ]
import ./[instructions, node, logger, interop_partial_message]

logScope:
  topics = "gossipsub-interop"

type ScriptRunner* = ref object
  nodeId*: int
  node*: GossipSub
  logStream*: Stream
  resolveAddr*: proc(nodeId: int): MultiAddress {.gcsafe, raises: [CatchableError].}
  startTime: Moment
  messages*: Table[string, InteropPartialMessage]

proc setResolveAddr*(
    runner: ScriptRunner,
    resolve: proc(nodeId: int): MultiAddress {.gcsafe, raises: [CatchableError].},
) =
  runner.resolveAddr = resolve

proc makeKey*(topicId: string, groupId: uint64): string =
  TableKey.makeKey(topicId, groupId)

proc makeKey(topicId: string, groupId: seq[byte]): string =
  makeKey(topicId, fromBytesBE(uint64, groupId.toOpenArray(0, GroupIdLen - 1)))

proc addReceivedMessageLogger(runner: ScriptRunner) =
  let logStream = runner.logStream

  runner.node.addObserver(
    PubSubObserver(
      onRecv: proc(peer: PubSubPeer, rpc: var RPCMsg) {.gcsafe, raises: [].} =
        for msg in rpc.messages:
          if msg.topic notin runner.node.topics or msg.data.len < 8:
            continue

          let msgId = extractMsgId(msg.data)
          logReceivedMessage(logStream, $msgId, msg.topic)
    )
  )

proc makePartialMessageConfig(runner: ScriptRunner): PartialMessageExtensionConfig =
  ## Create a PartialMessageExtensionConfig wired to this runner.
  ## runner.node must be set after node creation but before any RPC processing.

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    ok()

  proc onIncomingRPC(
      peer: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    if rpc.groupID.len != GroupIdLen:
      warn "Incoming RPC has invalid groupID length", len = rpc.groupID.len
      return

    let groupId = fromBytesBE(uint64, rpc.groupID)
    logReceivedPartialMessage(runner.logStream, rpc.topicID, groupId, peer)

    let key = makeKey(rpc.topicID, rpc.groupID)
    let pm =
      runner.messages.mgetOrPut(key, InteropPartialMessage.fromBytes(rpc.groupID))

    if rpc.partialMessage.len > 0:
      let before = pm.partsMetadata()
      let extendRes = pm.extend(rpc.partialMessage)
      if extendRes.isErr():
        warn "Failed to extend partial message", error = extendRes.error
        return

      if pm.partsMetadata() != before:
        if pm.isComplete():
          logAllPartsReceived(runner.logStream, groupId)

    doAssert runner.node != nil, "runner.node must be set before RPC processing"

    asyncSpawn runner.node.publishPartial(rpc.topicID, pm)

  PartialMessageExtensionConfig(
    unionPartsMetadata: interopUnionPartsMetadata,
    validateRPC: validateRPC,
    onIncomingRPC: onIncomingRPC,
    heartbeatsTillEviction: 100,
  )

proc newScriptRunner*(
    nodeId: int,
    logStream: Stream,
    listenAddr: MultiAddress,
    gossipSubParams: GossipSubParams = GossipSubParams.init(),
    resolveAddr: proc(nodeId: int): MultiAddress {.gcsafe, raises: [CatchableError].} =
      nil,
    enablePartialMessages: bool = false,
): ScriptRunner =
  let runner =
    ScriptRunner(nodeId: nodeId, logStream: logStream, resolveAddr: resolveAddr)
  let pmConfig =
    if enablePartialMessages:
      Opt.some(runner.makePartialMessageConfig())
    else:
      Opt.none(PartialMessageExtensionConfig)
  runner.node = createNode(nodeId, listenAddr, gossipSubParams, pmConfig)
  runner.addReceivedMessageLogger()
  runner

proc start*(runner: ScriptRunner) {.async.} =
  await runner.node.switch.start()

proc stop*(runner: ScriptRunner) {.async.} =
  await runner.node.switch.stop()

# Forward declaration
proc executeInstruction*(runner: ScriptRunner, instruction: ScriptInstruction) {.async.}

proc executeConnect(runner: ScriptRunner, connectTo: seq[int]) {.async.} =
  doAssert runner.resolveAddr != nil,
    "resolveAddr must be set before executing Connect instructions"

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

proc executeSubscribeToTopic(
    runner: ScriptRunner, topicId: string, partial: bool
) {.async.} =
  runner.node.subscribe(
    topicId, nil, requestsPartial = partial, supportsSendingPartial = partial
  )

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

proc executeAddPartialMessage(
    runner: ScriptRunner, topicId: string, groupId: uint64, partsBitmap: uint8
) {.async.} =
  let pm = InteropPartialMessage.new(groupId)
  pm.fillParts(InteropPartsMetadata.init(partsBitmap))

  let key = makeKey(topicId, groupId)
  runner.messages[key] = pm

  if pm.isComplete():
    logAllPartsReceived(runner.logStream, groupId)

proc executePublishPartial(
    runner: ScriptRunner, topicId: string, groupId: uint64, publishToNodeIDs: seq[int]
) {.async.} =
  let key = makeKey(topicId, groupId)
  doAssert key in runner.messages,
    "partial message not found for topic=" & topicId & " groupId=" & $groupId

  let pm = runner.messages[key]

  var peers: seq[PeerId]
  for nodeId in publishToNodeIDs:
    peers.add(nodePeerId(nodeId))

  await runner.node.publishPartial(topicId, pm, peers)

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
    await runner.executeSubscribeToTopic(instruction.topicID, instruction.partial)
  of Publish:
    await runner.executePublish(
      instruction.publishTopicID, instruction.messageSizeBytes,
      instruction.publishMessageID,
    )
  of SetTopicValidationDelay:
    await runner.executeSetTopicValidationDelay(
      instruction.validationTopicID, instruction.delay
    )
  of AddPartialMessage:
    await runner.executeAddPartialMessage(
      instruction.addTopicID, instruction.groupID, instruction.partsBitmap
    )
  of PublishPartial:
    await runner.executePublishPartial(
      instruction.publishPartialTopicID, instruction.publishPartialGroupID,
      instruction.publishToNodeIDs,
    )

proc runScript*(runner: ScriptRunner, instructions: seq[ScriptInstruction]) {.async.} =
  ## Execute a sequence of script instructions.
  runner.startTime = Moment.now()
  let peerId = PeerId.init(nodePrivKey(runner.nodeId)).expect("valid peer id")
  logPeerId(runner.logStream, peerId, runner.nodeId)

  for instr in instructions:
    await runner.executeInstruction(instr)
