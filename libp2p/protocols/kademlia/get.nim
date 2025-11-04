# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[times, tables, sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types, find, put]

proc dispatchGetVal(
    switch: Switch,
    peer: PeerId,
    key: Key,
    received: ReceivedTable,
    candidates: CandidatePeers,
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(msgType: MessageType.getValue, key: key)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    error "GetValue reply decode fail", error = error, conn = conn
    return

  received[peer] = Opt.none(EntryRecord)

  for peer in reply.closerPeers:
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", error = error
      continue
    candidates[].incl(p)

  let record = reply.record.valueOr:
    debug "GetValue returned empty record", msg = msg, reply = reply, conn = conn
    return

  let value = record.value.valueOr:
    debug "GetValue returned record with no value",
      msg = msg, reply = reply, conn = conn
    return

  let time = record.timeReceived.valueOr:
    debug "GetValue returned record with no timeReceived",
      msg = msg, reply = reply, conn = conn
    return

  received[peer] = Opt.some(EntryRecord(value: value, time: time))

proc bestValidRecord(
    kad: KadDHT, key: Key, received: ReceivedTable
): Result[EntryRecord, string] =
  var validRecords: seq[EntryRecord]
  for r in received.values():
    let record = r.valueOr:
      continue
    if kad.config.validator.isValid(key, record):
      validRecords.add(record)

  if validRecords.len() < kad.config.quorum:
    return err("Not enough valid records to achieve quorum")

  let selectedIdx = kad.config.selector.select(key, validRecords).valueOr:
    return err("Could not select best value")

  ok(validRecords[selectedIdx])

proc getValue*(
    kad: KadDHT, key: Key
): Future[Result[EntryRecord, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let candidates = CandidatePeers()
  for p in (await kad.findNode(key)):
    candidates[].incl(p)
  let received = ReceivedTable()

  var curTry = 0
  while received.len < kad.config.quorum and candidates[].len > 0 and
      curTry < kad.config.retries:
    for chunk in candidates[].toSeq.toChunks(kad.config.alpha):
      let rpcBatch =
        candidates[].mapIt(kad.switch.dispatchGetVal(it, key, received, candidates))
      try:
        await rpcBatch.allFutures().wait(kad.config.timeout)
      except AsyncTimeoutError:
        # Dispatch will timeout if any of the calls don't receive a response (which is normal)
        discard
    # filter out peers that have responded
    candidates[] = candidates[].filterIt(not received.hasKey(it))
    curTry.inc()

  let best = ?kad.bestValidRecord(key, received)

  # insert value to our localtable
  kad.dataTable.insert(key, best.value, $times.now().utc)

  # update peers that
  # - don't have best value
  # - don't have valid records
  # - don't have the values at all
  var rpcBatch: seq[Future[void]]
  for p, r in received:
    let record = r.valueOr:
      # peer doesn't have value
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value))
      continue
    if record.value != best.value:
      # value is invalid or not best
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value))

  try:
    await rpcBatch.allFutures().wait(chronos.seconds(5))
  except AsyncTimeoutError:
    # Dispatch will timeout if any of the calls don't receive a response (which is normal)
    discard

  ok(best)

proc handleGetValue*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let key = msg.key

  let entryRecord = kad.dataTable.get(key).valueOr:
    try:
      await conn.writeLp(
        Message(
          msgType: MessageType.getValue,
          key: key,
          closerPeers: kad.findClosestPeers(key),
        ).encode().buffer
      )
    except LPStreamError as exc:
      debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return

  try:
    await conn.writeLp(
      Message(
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
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return
