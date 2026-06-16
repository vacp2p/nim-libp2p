# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronicles
import protobuf_serialization, protobuf_serialization/pkg/results
import messages, ../../../[peerid], ../../../utils/[opt, protobuf]

export results

logScope:
  topics = "libp2p pubsubprotobuf"

when defined(libp2p_protobuf_metrics):
  import metrics

  declareCounter(
    libp2p_pubsub_rpc_bytes_read, "pubsub rpc bytes read", labels = ["kind"]
  )
  declareCounter(
    libp2p_pubsub_rpc_bytes_write, "pubsub rpc bytes write", labels = ["kind"]
  )

Protobuf.serializerFor(
  [
    PeerInfoMsg, SubOpts, ControlGraft, ControlIHave, ControlIWant, ControlPrune,
    ControlExtensions, ControlMessage, Preamble, IMReceiving, TestExtensionRPC,
    PartialMessageExtensionRPC, PingPongExtensionRPC, PreambleExtensionRPC, Message,
    RPCMsg,
  ]
)

proc encodeMessage*(msg: Message, anonymize: bool): seq[byte] =
  if not anonymize:
    return msg.encode()
  Message(data: msg.data, topic: msg.topic).encode()

proc encodeRpcMsg*(msg: RPCMsg, anonymize: bool): seq[byte] =
  trace "encodeRpcMsg: encoding message", rpcMsg = msg.shortLog()
  let encoded =
    if anonymize and msg.messages.len > 0:
      var anonMsg = msg
      for m in anonMsg.messages.mitems:
        m.fromPeer = default(PeerId)
        m.seqno = @[]
        m.signature = @[]
        m.key = @[]
      anonMsg.encode()
    else:
      msg.encode()

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(encoded.len.int64, labelValues = ["rpc"])

  encoded

proc decodeRpcMsg*(msg: sink seq[byte]): Result[RPCMsg, string] =
  trace "decodeRpcMsg: decoding message", encodedData = msg.shortLog()

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(msg.len.int64, labelValues = ["rpc"])

  let rpcMsg = ?RPCMsg.decode(move(msg))
  for m in rpcMsg.messages:
    if m.topic.len == 0:
      return err("Message missing required topic field")
  ok(rpcMsg)
