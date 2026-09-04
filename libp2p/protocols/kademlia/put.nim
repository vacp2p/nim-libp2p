# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../../utils/[heartbeat, future]
import ../protocol
import ./[protobuf, types, find, rpc, kademlia_metrics]

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
    trace "Failed to parse record timestamp, treating as expired", time = record.time
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
      trace "Expired record removed", key = key

proc dispatchPutVal*(
    kad: KadDHT, peer: PeerId, key: Key, value: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let msg = Message(
    msgType: Opt.some(MessageType.putValue),
    key: Opt.some(key),
    record: Opt.some(Record(key: Opt.some(key), value: Opt.some(value))),
  )
  let reply = ?await kad.dispatchRpc(peer, msg)

  trace "Got PutValue reply", msg = msg, reply = reply, peer = peer

  if reply != msg:
    trace "Unexpected change between msg and reply: ",
      msg = msg, reply = reply, peer = peer

  ok()

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
    trace "No record in message buffer", msg = msg, stream = stream
    return

  let msgKey = msg.key.valueOr:
    trace "Key not set: handlePutValue", msg = msg, stream = stream
    return

  if record.key.isNone or record.key.get() != msgKey:
    trace "Record key is different than Message key", msg = msg, stream = stream
    return

  let value = record.value.valueOr:
    trace "No value in record", msg = msg, stream = stream
    return

  if value.len > kad.config.limits.maxValueSize:
    trace "PUT_VALUE dropped: value exceeds maxValueSize",
      stream = stream, size = value.len, cap = kad.config.limits.maxValueSize
    await stream.reset()
    return

  let entryRecord = EntryRecord(value: value, time: Timestamp.now())

  # Value sanitisation done. Start insertion process
  if not kad.config.validator.isValid(msgKey, entryRecord):
    trace "Record is not valid", msg = msg, entryRecord = entryRecord
    return

  if not kad.isBestValue(msgKey, entryRecord):
    trace "Dropping received value, we have a better one"
    await stream.reset()
    return

  if not kad.canStoreLocalRecord(msgKey):
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
    trace "Failed to send find-node RPC reply", stream = stream, err = exc.msg
    return
