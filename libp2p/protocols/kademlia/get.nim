# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/tables
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../../utils/future
import ../protocol
import ./[protobuf, types, find, put, kademlia_metrics]

logScope:
  topics = "kad-dht get"

proc dispatchGetVal*(
    kad: KadDHT, peer: PeerId, key: Key
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  withRpcSlot(kad):
    let streamRes = catch:
      await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
    if streamRes.isErr:
      return err(streamRes.error.msg)
    let stream = streamRes.value()
    defer:
      await stream.close()

    let msg = Message(msgType: MessageType.getValue, key: key)
    let encoded = msg.encode(kad.config.hideConnectionStatus)

    kad_messages_sent.inc(labelValues = [$MessageType.getValue])
    kad_message_bytes_sent.inc(
      encoded.buffer.len.int64, labelValues = [$MessageType.getValue]
    )

    var replyBuf: seq[byte]
    var ioRes: Result[void, ref CatchableError]
    kad_message_duration_ms.time(labelValues = [$MessageType.getValue]):
      ioRes = catch:
        await stream.writeLp(encoded.buffer)
        replyBuf = await stream.readLp(MaxMsgSize)
    if ioRes.isErr:
      return err(ioRes.error.msg)

    kad_message_bytes_received.inc(
      replyBuf.len.int64, labelValues = [$MessageType.getValue]
    )

    let reply = Message.decode(replyBuf).valueOr:
      return err("GetValue reply decode fail")

    if reply.closerPeers.len > 0:
      kad_responses_with_closer_peers.inc(labelValues = [$MessageType.getValue])

    stream.observedAddr.withValue(observedAddr):
      kad.updatePeers(@[PeerInfo(peerId: stream.peerId, addrs: @[observedAddr])])

    return ok(reply)

proc bestValidRecord(
    kad: KadDHT, key: Key, received: ReceivedTable, quorum: int
): Result[EntryRecord, string] =
  var validRecords: seq[EntryRecord]
  for r in received.values():
    let record = r.valueOr:
      continue
    if kad.config.validator.isValid(key, record):
      validRecords.add(record)

  if validRecords.len() < quorum:
    return err(
      "Not enough valid records to achieve quorum, needed " & $quorum & " got " &
        $validRecords.len()
    )

  let selectedIdx = kad.config.selector.select(key, validRecords).valueOr:
    return err("Could not select best value")

  ok(validRecords[selectedIdx])

proc getValue*(
    kad: KadDHT, key: Key, quorumOverride: Opt[int] = Opt.none(int)
): Future[Result[EntryRecord, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let received = ReceivedTable()

  # if locally present and not expired, include our own copy
  kad.dataTable.get(key).withValue(localRecord):
    if not localRecord.isExpired(kad.config.recordExpirationInterval):
      received[kad.switch.peerInfo.peerId] = Opt.some(localRecord)
    else:
      kad.dataTable.del(key)
      debug "Local record expired on read", key = key

  let quorum = quorumOverride.valueOr:
    kad.config.quorum

  let onReply = proc(
      peer: PeerId, msgOpt: Opt[Message], state: var LookupState
  ): Future[void] {.async: (raises: []), gcsafe.} =
    if not received.hasKey(peer) and received.len >= kad.config.maxReceivedSize:
      debug "GetValue: ReceivedTable cap reached, dropping reply",
        peer = peer, cap = kad.config.maxReceivedSize
      return

    received[peer] = Opt.none(EntryRecord)

    let reply = msgOpt.valueOr:
      debug "Empty reply"
      return

    let record = reply.record.valueOr:
      debug "GetValue returned empty record", reply = reply
      return

    if record.key != key:
      debug "GetValue returned record with mismatched key",
        expected = key, got = record.key
      return

    let value = record.value.valueOr:
      debug "GetValue returned record with no value", reply = reply
      return

    if value.len > kad.config.maxValueSize:
      debug "GetValue dropped: value exceeds maxValueSize",
        peer = peer, size = value.len, cap = kad.config.maxValueSize
      return

    let time = record.timeReceived.valueOr:
      debug "GetValue returned record with no timeReceived, using current time instead",
        reply = reply
      Timestamp.now()

    received[peer] = Opt.some(EntryRecord(value: value, time: time))

  let stop = proc(state: LookupState): bool {.gcsafe.} =
    received.len >= quorum

  discard await kad.iterativeLookup(key, dispatchGetVal, onReply, stop)

  let best = ?kad.bestValidRecord(key, received, quorum)

  # insert value to our localtable
  kad.dataTable.insert(key, best.value, Timestamp.now())

  # update peers that
  # - don't have best value
  # - don't have valid records
  # - don't have the values at all
  var rpcBatch: seq[Future[Result[void, string]]]
  for p, r in received:
    let record = r.valueOr:
      # peer doesn't have value
      rpcBatch.add(kad.dispatchPutVal(p, key, best.value))
      continue
    if record.value != best.value:
      # value is invalid or not best
      rpcBatch.add(kad.dispatchPutVal(p, key, best.value))

  await rpcBatch.allFuturesWaitOrTimeout(kad.config.timeout)

  ok(best)

method handleGetValue*(
    kad: KadDHT, stream: Stream, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  let key = msg.key

  # Evict the entry eagerly if it has expired so the `valueOr` below treats it
  # as absent and sends the standard "no record found" response.
  var entryRecordOpt = kad.dataTable.get(key)
  entryRecordOpt.withValue(record):
    if record.isExpired(kad.config.recordExpirationInterval):
      debug "record expired, dropping", key = key
      kad.dataTable.del(key)
      entryRecordOpt = Opt.none(EntryRecord)

  let entryRecord = entryRecordOpt.valueOr:
    let response = Message(
      msgType: MessageType.getValue, key: key, closerPeers: kad.findClosestPeers(key)
    )
    let encoded = response.encode(kad.config.hideConnectionStatus)
    kad_message_bytes_sent.inc(
      encoded.buffer.len.int64, labelValues = [$MessageType.getValue]
    )
    try:
      await stream.writeLp(encoded.buffer)
    except LPStreamError as exc:
      debug "Failed to send get-value RPC reply", stream = stream, err = exc.msg
    return

  let response = Message(
    msgType: MessageType.getValue,
    key: key,
    record: Opt.some(
      Record(
        key: key,
        value: Opt.some(entryRecord.value),
        timeReceived: Opt.some(entryRecord.time),
      )
    ),
    closerPeers: kad.findClosestPeers(key),
  )
  let encoded = response.encode(kad.config.hideConnectionStatus)
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.getValue]
  )
  try:
    await stream.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send get-value RPC reply", stream = stream, err = exc.msg
    return
