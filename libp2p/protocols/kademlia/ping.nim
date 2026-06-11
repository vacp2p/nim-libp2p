# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types, kademlia_metrics]

proc ping*(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]
): Future[bool] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let stream = await kad.switch.dial(peerId, addrs, kad.codec)
  defer:
    await stream.close()

  let request = Message(msgType: MessageType.ping)
  let encoded = request.encode(kad.config.hideConnectionStatus)

  kad_messages_sent.inc(labelValues = [$MessageType.ping])
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.ping])

  var replyBuf: seq[byte]
  kad_message_duration_ms.time(labelValues = [$MessageType.ping]):
    await stream.writeLp(encoded)
    replyBuf = await stream.readLp(MaxMsgSize)

  kad_message_bytes_received.inc(replyBuf.len.int64, labelValues = [$MessageType.ping])

  let reply = Message.decode(replyBuf).valueOr:
    return false

  return reply == request

proc handlePing*(
    kad: KadDHT, stream: Stream, msg: Message
) {.async: (raises: [CancelledError]).} =
  let encoded = msg.encode(kad.config.hideConnectionStatus)
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.ping])
  try:
    await stream.writeLp(encoded)
  except LPStreamError as exc:
    debug "Failed to send ping reply", stream = stream, err = exc.msg
    return
