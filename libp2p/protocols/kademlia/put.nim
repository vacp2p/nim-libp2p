# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[times, sequtils]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types, find, kademlia_metrics]

logScope:
  topics = "kad-dht put"

proc isBestValue(kad: KadDHT, key: Key, record: EntryRecord): bool =
  ## Returns whether `value` is a better value than what we have locally
  ## Always returns `true` if we don't have the value locally

  kad.dataTable.get(key).withValue(existing):
    kad.config.selector.select(key, @[record, existing]).withValue(selectedIdx):
      return selectedIdx == 0
  return true

proc dispatchPutVal*(
    switch: Switch, peer: PeerId, key: Key, value: seq[byte], codec: string
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, switch.peerStore[AddressBook][peer], codec)
  defer:
    await conn.close()
  let msg = Message(
    msgType: MessageType.putValue,
    key: key,
    record: Opt.some(Record(key: key, value: Opt.some(value))),
  )
  let encoded = msg.encode()

  kad_messages_sent.inc(labelValues = [$MessageType.putValue])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.putValue]
  )

  var replyBuf: seq[byte]
  kad_message_duration_ms.time(labelValues = [$MessageType.putValue]):
    await conn.writeLp(encoded.buffer)
    replyBuf = await conn.readLp(MaxMsgSize)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.putValue]
  )

  let reply = Message.decode(replyBuf).valueOr:
    error "PutValue reply decode fail", error = error, conn = conn
    return

  if reply != msg:
    error "Unexpected change between msg and reply: ",
      msg = msg, reply = reply, conn = conn

  debug "Got PutValue reply", msg = msg, reply = reply, conn = conn

proc putValue*(
    kad: KadDHT, key: Key, value: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let record = EntryRecord(value: value, time: $times.now().utc)

  if not kad.config.validator.isValid(key, record):
    return err("invalid key/value pair")

  if not kad.isBestValue(key, record):
    return err("Value rejected, we have a better one")

  let peers = await kad.findNode(key)

  kad.dataTable.insert(key, value, $times.now().utc)

  for chunk in peers.toChunks(kad.config.alpha):
    let rpcBatch = chunk.mapIt(kad.switch.dispatchPutVal(it, key, value, kad.codec))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      debug "One or more PutValue messages timed out"
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

  ok()

proc handlePutValue*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let record = msg.record.valueOr:
    error "No record in message buffer", msg = msg, conn = conn
    return

  if record.key != msg.key:
    error "Record key is different than Message key", msg = msg, conn = conn
    return

  let value = record.value.valueOr:
    error "No value in record", msg = msg, conn = conn
    return

  let entryRecord = EntryRecord(value: value, time: $times.now().utc)

  # Value sanitisation done. Start insertion process
  if not kad.config.validator.isValid(msg.key, entryRecord):
    debug "Record is not valid", msg = msg.key, entryRecord = entryRecord
    return

  if not kad.isBestValue(msg.key, entryRecord):
    error "Dropping received value, we have a better one"
    return

  kad.dataTable.insert(msg.key, entryRecord.value, $times.now().utc)
  # consistent with following link, echo message without change
  # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
  let encoded = msg.encode()
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.putValue]
  )
  try:
    await conn.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send find-node RPC reply", conn = conn, err = exc.msg
    return
