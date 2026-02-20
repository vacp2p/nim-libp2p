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
  let conn = await kad.switch.dial(peerId, addrs, kad.codec)
  defer:
    await conn.close()

  let request = Message(msgType: MessageType.ping)
  let encoded = request.encode()

  kad_messages_sent.inc(labelValues = [$MessageType.ping])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.ping]
  )

  var replyBuf: seq[byte]
  kad_message_duration_ms.time(labelValues = [$MessageType.ping]):
    await conn.writeLp(encoded.buffer)
    replyBuf = await conn.readLp(MaxMsgSize)

  kad_message_bytes_received.inc(replyBuf.len.int64, labelValues = [$MessageType.ping])

  let reply = Message.decode(replyBuf).tryGet()

  reply == request

proc handlePing*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let encoded = msg.encode()
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.ping]
  )
  try:
    await conn.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send ping reply", conn = conn, err = exc.msg
    return
