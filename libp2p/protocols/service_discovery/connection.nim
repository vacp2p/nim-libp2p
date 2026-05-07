# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record]
import ../kademlia
import ../kademlia/types
import ./[types, service_discovery_metrics, registrar]

logScope:
  topics = "service-disco connection"

proc send*(
    disco: ServiceDiscovery, peerId: PeerId, msg: Message
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return err("no address found for peer: " & $peerId)

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  let encodedMsg = msg.encode().buffer

  cd_messages_sent.inc(labelValues = [$msg.msgType])
  cd_message_bytes_sent.inc(encodedMsg.len.float64, labelValues = [$msg.msgType])

  var writeRes: Result[void, ref CatchableError]
  var readRes: Result[seq[byte], ref CatchableError]
  cd_message_duration_ms.time(labelValues = [$msg.msgType]):
    writeRes = catch:
      await conn.writeLp(encodedMsg)
    readRes = catch:
      await conn.readLp(MaxMsgSize)

  if writeRes.isErr:
    return err("connection writing failed: " & writeRes.error.msg)
  let replyBuf = readRes.valueOr:
    return err("connection reading failed: " & readRes.error.msg)

  cd_messages_received.inc(labelValues = [$msg.msgType])
  cd_message_bytes_received.inc(replyBuf.len.float64, labelValues = [$msg.msgType])

  let reply = Message.decode(replyBuf).valueOr:
    return err("failed to decode message response: " & $error)

  return ok(reply)

proc handleMessage*(
    disco: ServiceDiscovery, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  cd_messages_received.inc(labelValues = [$msg.msgType])

  let response =
    if msg.msgType == MessageType.register:
      disco.registration(msg)
    else:
      disco.getAdvertisements(msg)

  let bytes = response.encode().buffer

  cd_messages_sent.inc(labelValues = [$msg.msgType])
  cd_message_bytes_sent.inc(bytes.len.float64, labelValues = [$msg.msgType])

  let writeRes = catch:
    await conn.writeLp(bytes)
  if writeRes.isErr:
    error "failed to send message response", error = writeRes.error.msg
