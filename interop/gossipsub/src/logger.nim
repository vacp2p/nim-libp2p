# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import json, times, streams
import ../../../libp2p/peerid

proc logJSON*(
    stream: Stream, msg: string, fields: openArray[(string, string)]
) {.raises: [IOError, OSError].} =
  ## Write a structured JSON log line to the given stream.
  var obj =
    %*{
      "time": now().format("yyyy-MM-dd'T'HH:mm:ss'.'ffffffzzz"),
      "level": "INFO",
      "msg": msg,
      "service": "gossipsub",
    }
  for (key, val) in fields:
    obj[key] = %val
  stream.writeLine($obj)
  stream.flush()

proc logPeerId*(
    stream: Stream, peerId: PeerId, nodeId: int
) {.raises: [IOError, OSError].} =
  ## Log the PeerID event (required at startup).
  logJSON(stream, "PeerID", {"id": $peerId, "node_id": $nodeId})

proc logReceivedMessage*(
    stream: Stream, msgId: string, topic: string
) {.raises: [IOError, OSError].} =
  ## Log a received message event.
  logJSON(stream, "Received Message", {"id": msgId, "topic": topic})
