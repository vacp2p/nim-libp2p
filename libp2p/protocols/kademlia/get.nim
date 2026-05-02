# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[times, tables]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types, find, put, kademlia_metrics]

logScope:
  topics = "kad-dht get"

proc dispatchGetVal*(
    kad: KadDHT, peer: PeerId, key: Key
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let connRes = catch:
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
  if connRes.isErr:
    return err(connRes.error.msg)
  let conn = connRes.value()
  defer:
    await conn.close()

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
      await conn.writeLp(encoded.buffer)
      replyBuf = await conn.readLp(MaxMsgSize)
  if ioRes.isErr:
    return err(ioRes.error.msg)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.getValue]
  )

  let reply = Message.decode(replyBuf).valueOr:
    return err("GetValue reply decode fail")

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$MessageType.getValue])

  conn.observedAddr.withValue(observedAddr):
    kad.updatePeers(@[PeerInfo(peerId: conn.peerId, addrs: @[observedAddr])])

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
    if not localRecord.isDataEntryExpired(kad.config.dataEntryExpirationInterval):
      received[kad.switch.peerInfo.peerId] = Opt.some(localRecord)
    else:
      kad.dataTable.del(key)
      debug "Local data entry expired on read", key = key

  let quorum = quorumOverride.valueOr:
    kad.config.quorum

  let onReply = proc(
      peer: PeerId, msgOpt: Opt[Message], state: var LookupState
  ): Future[void] {.async: (raises: []), gcsafe.} =
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

    let time = record.timeReceived.valueOr:
      debug "GetValue returned record with no timeReceived, using current time instead",
        reply = reply
      TimeStamp($times.now().utc)

    received[peer] = Opt.some(EntryRecord(value: value, time: time))

  let stop = proc(state: LookupState): bool {.gcsafe.} =
    received.len >= quorum

  discard await kad.iterativeLookup(key, dispatchGetVal, onReply, stop)

  let best = ?kad.bestValidRecord(key, received, quorum)

  # insert value to our localtable
  kad.dataTable.insert(key, best.value, $times.now().utc)

  # update peers that
  # - don't have best value
  # - don't have valid records
  # - don't have the values at all
  var rpcBatch: seq[Future[Result[void, string]]]
  for p, r in received:
    let record = r.valueOr:
      # peer doesn't have value
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value, kad.codec))
      continue
    if record.value != best.value:
      # value is invalid or not best
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value, kad.codec))

  try:
    await rpcBatch.allFutures().wait(chronos.seconds(5))
  except AsyncTimeoutError:
    # Dispatch will timeout if any of the calls don't receive a response (which is normal)
    discard

  ok(best)

method handleGetValue*(
    kad: KadDHT, conn: Connection, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  let key = msg.key

  let entryRecord = kad.dataTable.get(key).valueOr:
    let response = Message(
      msgType: MessageType.getValue, key: key, closerPeers: kad.findClosestPeers(key)
    )
    let encoded = response.encode(kad.config.hideConnectionStatus)
    kad_message_bytes_sent.inc(
      encoded.buffer.len.int64, labelValues = [$MessageType.getValue]
    )
    try:
      await conn.writeLp(encoded.buffer)
    except LPStreamError as exc:
      debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return

  if entryRecord.isDataEntryExpired(kad.config.dataEntryExpirationInterval):
    debug "Data entry expired, dropping", key = key
    kad.dataTable.del(key)
    let response = Message(
      msgType: MessageType.getValue, key: key, closerPeers: kad.findClosestPeers(key)
    )
    let encoded = response.encode(kad.config.hideConnectionStatus)
    kad_message_bytes_sent.inc(
      encoded.buffer.len.int64, labelValues = [$MessageType.getValue]
    )
    try:
      await conn.writeLp(encoded.buffer)
    except LPStreamError as exc:
      debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
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
    await conn.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return
