# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import json, times, streams, chronicles
import ../../../libp2p/peerid

logScope:
  topics = "gossipsub-interop"

proc logJSON*(
    stream: Stream, msg: string, fields: openArray[(string, string)]
) {.raises: [].} =
  ## Write a structured JSON log line to the given stream.
  try:
    var obj = %*{
      "time": now().format("yyyy-MM-dd'T'HH:mm:ss'.'ffffffzzz"),
      "level": "INFO",
      "msg": msg,
      "service": "gossipsub",
    }
    for (key, val) in fields:
      obj[key] = %val
    stream.writeLine($obj)
    stream.flush()
  except IOError as e:
    warn "Log write failed", logMsg = msg, error = e.msg
  except OSError as e:
    warn "Log write failed", logMsg = msg, error = e.msg

proc logPeerId*(stream: Stream, peerId: PeerId, nodeId: int) {.raises: [].} =
  ## Log the PeerID event (required at startup).
  logJSON(stream, "PeerID", {"id": $peerId, "node_id": $nodeId})

proc logReceivedMessage*(stream: Stream, msgId: string, topic: string) {.raises: [].} =
  ## Log a received message event.
  logJSON(stream, "Received Message", {"id": msgId, "topic": topic})

proc logReceivedPartialMessage*(
    stream: Stream, topic: string, groupId: uint64, fromPeer: PeerId
) {.raises: [].} =
  ## Log a received partial message event.
  logJSON(
    stream,
    "Received Partial Message",
    {"topic": topic, "group_id": $groupId, "from": $fromPeer},
  )

proc logAllPartsReceived*(stream: Stream, groupId: uint64) {.raises: [].} =
  ## Log that all parts of a partial message have been received.
  logJSON(stream, "All parts received", {"group_id": $groupId})
