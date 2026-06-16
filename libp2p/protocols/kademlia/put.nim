# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../../utils/[heartbeat, future]
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

proc isExpired*(
    record: EntryRecord,
    interval: chronos.Duration,
    currentUnixSeconds = nowUnixSeconds(),
): bool {.gcsafe, raises: [].} =
  ## Returns true when the record's stored timestamp is older than `interval`.
  ## Records whose timestamp cannot be parsed are treated as expired.
  let storedUnix = record.time.toUnixSeconds().valueOr:
    warn "Failed to parse record timestamp, treating as expired", time = record.time
    return true

  (currentUnixSeconds - storedUnix).seconds > interval

proc manageExpiredRecords*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  ## Periodically scans `dataTable` and evicts entries that are older than
  ## `config.recordExpirationInterval`. Runs indefinitely as a heartbeat
  ## loop until cancelled (e.g. via `cancelSoon` or `cancelAndWait`).
  heartbeat "cleanup expired data entries", kad.config.cleanupDataEntriesInterval:
    let currentUnixSeconds = nowUnixSeconds()
    var toRemove: seq[Key]
    for key, record in kad.dataTable:
      if record.isExpired(kad.config.recordExpirationInterval, currentUnixSeconds):
        toRemove.add(key)
    for key in toRemove:
      kad.dataTable.del(key)
      debug "Expired record removed", key = key

proc dispatchPutVal*(
    kad: KadDHT, peer: PeerId, key: Key, value: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  withRpcSlot(kad)
  let streamRes = catch:
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
  if streamRes.isErr:
    return err(streamRes.error.msg)
  let stream = streamRes.value()
  defer:
    await stream.close()
  let msg = Message(
    msgType: Opt.some(MessageType.putValue),
    key: Opt.some(key),
    record: Opt.some(Record(key: Opt.some(key), value: Opt.some(value))),
  )
  let encoded = msg.encode()

  kad_messages_sent.inc(labelValues = [$MessageType.putValue])
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.putValue])

  var replyBuf: seq[byte]
  var ioRes: Result[void, ref CatchableError]
  kad_message_duration_ms.time(labelValues = [$MessageType.putValue]):
    ioRes = catch:
      await stream.writeLp(encoded)
      replyBuf = await stream.readLp(MaxMsgSize)
  if ioRes.isErr:
    return err(ioRes.error.msg)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.putValue]
  )

  let reply = Message.decode(replyBuf).valueOr:
    return err("PutValue reply decode fail")

  debug "Got PutValue reply", msg = msg, reply = reply, stream = stream

  if reply != msg:
    error "Unexpected change between msg and reply: ",
      msg = msg, reply = reply, stream = stream

  return ok()

proc canStoreLocalRecord*(kad: KadDHT, key: Key): bool {.raises: [].} =
  if kad.dataTable.hasKey(key):
    return true
  kad.config.limits.maxLocalRecords.withValue(limit):
    return kad.dataTable.len < limit
  true

proc putValue*(
    kad: KadDHT, key: Key, value: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if value.len > kad.config.limits.maxValueSize:
    return err(
      "value exceeds maxValueSize (" & $value.len & " > " &
        $kad.config.limits.maxValueSize & ")"
    )

  let record = EntryRecord(value: value, time: Timestamp.now())

  if not kad.config.validator.isValid(key, record):
    return err("invalid key/value pair")

  if not kad.isBestValue(key, record):
    return err("Value rejected, we have a better one")

  let peers = await kad.findNode(key)

  if kad.canStoreLocalRecord(key):
    kad.dataTable.insert(key, value, Timestamp.now())
  else:
    debug "PutValue: local record limit reached", current = kad.dataTable.len

  for chunk in peers.toChunks(kad.config.alpha):
    let batch = chunk.mapIt(kad.dispatchPutVal(it, key, value))
    await batch.allFuturesWaitOrTimeout(kad.config.timeout)

  ok()

proc handlePutValue*(
    kad: KadDHT, stream: Stream, msg: Message
) {.async: (raises: [CancelledError]).} =
  let record = msg.record.valueOr:
    error "No record in message buffer", msg = msg, stream = stream
    return

  let msgKey = msg.key.valueOr:
    error "Key not set: handlePutValue", msg = msg, stream = stream
    return

  if record.key.isNone or record.key.get() != msgKey:
    error "Record key is different than Message key", msg = msg, stream = stream
    return

  let value = record.value.valueOr:
    error "No value in record", msg = msg, stream = stream
    return

  if value.len > kad.config.limits.maxValueSize:
    debug "PUT_VALUE dropped: value exceeds maxValueSize",
      stream = stream, size = value.len, cap = kad.config.limits.maxValueSize
    await stream.reset()
    return

  let entryRecord = EntryRecord(value: value, time: Timestamp.now())

  # Value sanitisation done. Start insertion process
  if not kad.config.validator.isValid(msgKey, entryRecord):
    debug "Record is not valid", msg = msg, entryRecord = entryRecord
    return

  if not kad.isBestValue(msgKey, entryRecord):
    error "Dropping received value, we have a better one"
    await stream.reset()
    return

  if not kad.canStoreLocalRecord(msg.key):
    debug "PutValue: local record limit reached",
      stream = stream, current = kad.dataTable.len
    await stream.reset()
    return

  kad.dataTable.insert(msgKey, entryRecord.value, Timestamp.now())
  # consistent with following link, echo message without change
  # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
  let encoded = msg.encode(kad.config.hideConnectionStatus)
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.putValue])
  try:
    await stream.writeLp(encoded)
  except LPStreamError as exc:
    debug "Failed to send find-node RPC reply", stream = stream, err = exc.msg
    return
