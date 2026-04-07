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

proc parseInstruction*(j: JsonNode): ScriptInstruction {.raises: [KeyError, ValueError].} =
  ## Parse a single JSON instruction into a ScriptInstruction.
  let instrType = j["type"].getStr()
  case instrType
  of "initGossipSub":
    result = ScriptInstruction(
      kind: InitGossipSub,
      gossipSubParams:
        if j.hasKey("gossipSubParams"):
          j["gossipSubParams"]
        else:
          newJObject()
      ,
    )
  of "connect":
    var targets: seq[int]
    for item in j["connectTo"]:
      targets.add(item.getInt())
    result = ScriptInstruction(kind: Connect, connectTo: targets)
  of "ifNodeIDEquals":
    let innerInstr = new ScriptInstruction
    innerInstr[] = parseInstruction(j["instruction"])
    result = ScriptInstruction(
      kind: IfNodeIDEquals, nodeID: j["nodeID"].getInt(), inner: innerInstr
    )
  of "waitUntil":
    result = ScriptInstruction(
      kind: WaitUntil, elapsedSeconds: j["elapsedSeconds"].getFloat()
    )
  of "subscribeToTopic":
    result = ScriptInstruction(
      kind: SubscribeToTopic,
      topicID: j["topicID"].getStr(),
      partial:
        if j.hasKey("partial"):
          j["partial"].getBool()
        else:
          false
      ,
    )
  of "publish":
    result = ScriptInstruction(
      kind: Publish,
      publishMessageID: j["messageID"].getInt(),
      messageSizeBytes: j["messageSizeBytes"].getInt(),
      publishTopicID: j["topicID"].getStr(),
    )
  of "setTopicValidationDelay":
    result = ScriptInstruction(
      kind: SetTopicValidationDelay,
      validationTopicID: j["topicID"].getStr(),
      delaySeconds: j["delaySeconds"].getFloat(),
    )
  else:
    raise newException(ValueError, "Unknown instruction type: " & instrType)

proc parseScript*(j: JsonNode): seq[ScriptInstruction] {.raises: [KeyError, ValueError].} =
  ## Parse the full experiment params JSON, extracting the script array.
  for item in j["script"]:
    result.add(parseInstruction(item))

proc loadParams*(
    path: string
): seq[ScriptInstruction] {.raises: [IOError, OSError, KeyError, ValueError].} =
  ## Load and parse params.json from file.
  let content = readFile(path)
  let j = parseJson(content)
  parseScript(j)
