# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import json

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
      gossipSubParams*: JsonNode
    of Connect:
      connectTo*: seq[int]
    of IfNodeIDEquals:
      nodeID*: int
      inner*: ref ScriptInstruction
    of WaitUntil:
      elapsedSeconds*: float64
    of SubscribeToTopic:
      topicID*: string
      partial*: bool
    of Publish:
      publishMessageID*: int
      messageSizeBytes*: int
      publishTopicID*: string
    of SetTopicValidationDelay:
      validationTopicID*: string
      delaySeconds*: float64

# Forward declaration
proc parseInstruction*(
  j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError].}

proc parseInitGossipSub(j: JsonNode): ScriptInstruction =
  ScriptInstruction(
    kind: InitGossipSub,
    gossipSubParams:
      if j.hasKey("gossipSubParams"):
        j["gossipSubParams"]
      else:
        newJObject(),
  )

proc parseConnect(j: JsonNode): ScriptInstruction =
  var targets: seq[int]
  for item in j["connectTo"]:
    targets.add(item.getInt())
  ScriptInstruction(kind: Connect, connectTo: targets)

proc parseIfNodeIDEquals(
    j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError].} =
  let innerInstr = new ScriptInstruction
  innerInstr[] = parseInstruction(j["instruction"])
  ScriptInstruction(
    kind: IfNodeIDEquals, nodeID: j["nodeID"].getInt(), inner: innerInstr
  )

proc parseWaitUntil(j: JsonNode): ScriptInstruction =
  ScriptInstruction(kind: WaitUntil, elapsedSeconds: j["elapsedSeconds"].getFloat())

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
    delaySeconds: j["delaySeconds"].getFloat(),
  )

proc parseInstruction*(
    j: JsonNode
): ScriptInstruction {.raises: [KeyError, ValueError].} =
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
): seq[ScriptInstruction] {.raises: [KeyError, ValueError].} =
  ## Parse the full experiment params JSON, extracting the script array.
  var instructions: seq[ScriptInstruction]
  for item in j["script"]:
    instructions.add(parseInstruction(item))
  instructions

proc loadParams*(
    path: string
): seq[ScriptInstruction] {.raises: [IOError, OSError, KeyError, ValueError].} =
  ## Load and parse params.json from file.
  parseScript(parseJson(readFile(path)))
