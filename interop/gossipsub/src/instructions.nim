# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, json, math
import ../../../libp2p/protocols/pubsub/gossipsub

type
  InstructionKind* = enum
    InitGossipSub = "initGossipSub"
    Connect = "connect"
    IfNodeIDEquals = "ifNodeIDEquals"
    WaitUntil = "waitUntil"
    SubscribeToTopic = "subscribeToTopic"
    Publish = "publish"
    SetTopicValidationDelay = "setTopicValidationDelay"

  ScriptInstruction* = object
    case kind*: InstructionKind
    of InitGossipSub:
      gossipSubParams*: GossipSubParams
    of Connect:
      connectTo*: seq[int]
    of IfNodeIDEquals:
      nodeID*: int
      inner*: ref ScriptInstruction
    of WaitUntil:
      elapsed*: Duration
    of SubscribeToTopic:
      topicID*: string
      partial*: bool
    of Publish:
      publishMessageID*: int
      messageSizeBytes*: int
      publishTopicID*: string
    of SetTopicValidationDelay:
      validationTopicID*: string
      delay*: Duration

proc parseDurationNano*(node: JsonNode): Duration =
  ## Parse a JSON number (int or float) as nanoseconds into a Duration.
  int64(node.getFloat()).nanoseconds()

proc parseDurationSec*(node: JsonNode): Duration =
  ## Parse a JSON number (int or float) as seconds into a Duration.
  let secs = node.getFloat()
  int64(round(secs * 1_000_000_000.0)).nanoseconds()

proc getDurationNano(node: JsonNode, default: Duration): Duration =
  if node == nil or node.kind == JNull:
    return default
  node.parseDurationNano()

proc toGossipSubParams*(j: JsonNode): GossipSubParams =
  ## Convert JSON to GossipSubParams
  var params = GossipSubParams.init()

  params.d = j.getOrDefault("D").getInt(params.d)
  params.dLow = j.getOrDefault("Dlo").getInt(params.dLow)
  params.dHigh = j.getOrDefault("Dhi").getInt(params.dHigh)
  params.dScore = j.getOrDefault("Dscore").getInt(params.dScore)
  params.dOut = j.getOrDefault("Dout").getInt(params.dOut)
  params.dLazy = j.getOrDefault("Dlazy").getInt(params.dLazy)

  params.historyLength = j.getOrDefault("HistoryLength").getInt(params.historyLength)
  params.historyGossip = j.getOrDefault("HistoryGossip").getInt(params.historyGossip)
  params.gossipFactor = j.getOrDefault("GossipFactor").getFloat(params.gossipFactor)

  params.heartbeatInterval =
    j.getOrDefault("HeartbeatInterval").getDurationNano(params.heartbeatInterval)
  params.fanoutTTL = j.getOrDefault("FanoutTTL").getDurationNano(params.fanoutTTL)
  params.pruneBackoff =
    j.getOrDefault("PruneBackoff").getDurationNano(params.pruneBackoff)
  params.unsubscribeBackoff =
    j.getOrDefault("UnsubscribeBackoff").getDurationNano(params.unsubscribeBackoff)
  params.seenTTL = j.getOrDefault("SeenTTL").getDurationNano(params.seenTTL)

  params.floodPublish = j.getOrDefault("FloodPublish").getBool(params.floodPublish)

  params

# Forward declaration
proc parseInstruction*(
  j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError], gcsafe.}

proc parseInitGossipSub(j: JsonNode): ScriptInstruction =
  let paramsJson =
    if j.hasKey("gossipSubParams"):
      j["gossipSubParams"]
    else:
      newJObject()
  ScriptInstruction(kind: InitGossipSub, gossipSubParams: toGossipSubParams(paramsJson))

proc parseConnect(j: JsonNode): ScriptInstruction =
  var targets: seq[int]
  for item in j["connectTo"]:
    targets.add(item.getInt())
  ScriptInstruction(kind: Connect, connectTo: targets)

proc parseIfNodeIDEquals(
    j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError], gcsafe.} =
  let innerInstr = new ScriptInstruction
  innerInstr[] = parseInstruction(j["instruction"])
  ScriptInstruction(
    kind: IfNodeIDEquals, nodeID: j["nodeID"].getInt(), inner: innerInstr
  )

proc parseWaitUntil(j: JsonNode): ScriptInstruction =
  ScriptInstruction(kind: WaitUntil, elapsed: j["elapsedSeconds"].parseDurationSec())

proc parseSubscribeToTopic(j: JsonNode): ScriptInstruction =
  ScriptInstruction(
    kind: SubscribeToTopic,
    topicID: j["topicID"].getStr(),
    partial:
      if j.hasKey("partial"):
        j["partial"].getBool()
      else:
        false,
  )

proc parsePublish(j: JsonNode): ScriptInstruction =
  ScriptInstruction(
    kind: Publish,
    publishMessageID: j["messageID"].getInt(),
    messageSizeBytes: j["messageSizeBytes"].getInt(),
    publishTopicID: j["topicID"].getStr(),
  )

proc parseSetTopicValidationDelay(j: JsonNode): ScriptInstruction =
  ScriptInstruction(
    kind: SetTopicValidationDelay,
    validationTopicID: j["topicID"].getStr(),
    delay: j["delaySeconds"].parseDurationSec(),
  )

proc parseInstruction*(
    j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError], gcsafe.} =
  ## Parse a single JSON instruction into a ScriptInstruction.
  let instrType = j["type"].getStr()
  case instrType
  of "initGossipSub":
    parseInitGossipSub(j)
  of "connect":
    parseConnect(j)
  of "ifNodeIDEquals":
    parseIfNodeIDEquals(j)
  of "waitUntil":
    parseWaitUntil(j)
  of "subscribeToTopic":
    parseSubscribeToTopic(j)
  of "publish":
    parsePublish(j)
  of "setTopicValidationDelay":
    parseSetTopicValidationDelay(j)
  else:
    raise newException(ValueError, "Unknown instruction type: " & instrType)

proc parseScript*(
    j: JsonNode
): seq[ScriptInstruction] {.raises: [KeyError, ValueError], gcsafe.} =
  ## Parse the full experiment params JSON, extracting the script array.
  var instructions: seq[ScriptInstruction]
  for item in j["script"]:
    instructions.add(parseInstruction(item))
  instructions

proc loadParams*(
    path: string
): seq[ScriptInstruction] {.raises: [IOError, OSError, KeyError, ValueError], gcsafe.} =
  ## Load and parse params.json from file.
  readFile(path).parseJson().parseScript()
