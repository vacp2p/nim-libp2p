# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## The outbound path every Kademlia request/response RPC shares: take an RPC
## slot, encode, send on the peer's reused stream, count the message metrics and
## decode the reply.

import chronos, results
import ../../[peerid, switch]
import ./[protobuf, types, kademlia_metrics]

proc dispatchRpc*(
    kad: KadDHT, peer: PeerId, addrs: seq[MultiAddress], msg: Message
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let msgType = msg.msgType.valueOr:
    return err("outbound RPC without a message type")

  withRpcSlot(kad)
  let encoded = msg.encode(kad.config.hideConnectionStatus)

  kad_messages_sent.inc(labelValues = [$msgType])
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$msgType])

  var sendRes: Result[seq[byte], SendError]
  kad_message_duration_ms.time(labelValues = [$msgType]):
    sendRes = await kad.msgSender.sendRequest(peer, addrs, encoded, kad.config.timeout)
  let replyBuf = sendRes.valueOr:
    return err($error)

  kad_message_bytes_received.inc(replyBuf.len.int64, labelValues = [$msgType])

  let reply = Message.decode(replyBuf).valueOr:
    return err($msgType & " reply decode fail")

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$msgType])

  ok(reply)
