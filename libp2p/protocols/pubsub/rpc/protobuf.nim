# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import protobuf_serialization, protobuf_serialization/pkg/results
import ../../../utils/[protobuf]
import ../../../[peerid]
import messages

Protobuf.serializerFor(
  [
    PeerInfoMsg, SubOpts, ControlGraft, ControlIHave, ControlIWant, ControlPrune,
    ControlExtensions, ControlMessage, Preamble, IMReceiving, TestExtensionRPC,
    PartialMessageExtensionRPC, PingPongExtensionRPC, PreambleExtensionRPC,
  ]
)

proc encode*(msg: Message, anonymize: bool): seq[byte] =
  var m = msg
  if anonymize:
    m = Message(data: msg.data, topic: msg.topic)
  encode(Protobuf, m)

proc decodeMessage(buf: seq[byte]): Message {.raises: [SerializationError].} =
  decode(Protobuf, buf, Message)

proc decode*(_: type Message, buf: seq[byte]): Result[Message, string] =
  try:
    ok(decodeMessage(buf))
  except SerializationError as e:
    err("failed to decode Message from protobuf bytes. " & e.msg)

proc encode*(msg: RPCMsg, anonymize: bool): seq[byte] =
  let msgToEncode =
    if anonymize and msg.messages.len > 0:
      var anonMsg = msg
      for m in anonMsg.messages.mitems:
        m.fromPeer = default(PeerId)
        m.seqno = @[]
        m.signature = @[]
        m.key = @[]
      anonMsg
    else:
      msg

  encode(Protobuf, msgToEncode)

proc decodeRPCMessage(buf: seq[byte]): RPCMsg {.raises: [SerializationError].} =
  decode(Protobuf, buf, RPCMsg)

proc decode*(_: type RPCMsg, buf: seq[byte]): Result[RPCMsg, string] =
  try:
    let msg = decodeRPCMessage(buf)

    for m in msg.messages:
      if m.topic.len == 0:
        return err("Message missing required topic field")

    ok(msg)
  except SerializationError as e:
    err("failed to decode RPCMsg from protobuf bytes. " & e.msg)
