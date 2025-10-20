# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[times, sequtils]
import chronos, chronicles, results
import ../../../[peerid, switch, multihash]
import ../../protocol
import ../[protobuf, types]
import ./find

proc isBestValue(kad: KadDHT, key: Key, record: EntryRecord): bool =
  ## Returns whether `value` is a better value than what we have locally
  ## Always returns `true` if we don't have the value locally

  kad.dataTable.get(key).withValue(existing):
    kad.config.selector.select(key, @[record, existing]).withValue(selectedIdx):
      return selectedIdx == 0
  return true

proc dispatchPutVal*(
    switch: Switch, peer: PeerId, key: Key, value: seq[byte]
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(
    msgType: MessageType.putValue,
    record: Opt.some(Record(key: Opt.some(key), value: Opt.some(value))),
  )
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    error "PutValue reply decode fail", error = error, conn = conn
    return
  if reply != msg:
    error "Unexpected change between msg and reply: ",
      msg = msg, reply = reply, conn = conn

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
    let rpcBatch = chunk.mapIt(kad.switch.dispatchPutVal(it, key, value))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

  ok()

proc handlePutValue*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let record = msg.record.valueOr:
    error "No record in message buffer", msg = msg, conn = conn
    return

  let (key, entryRecord) =
    try:
      (record.key.get(), EntryRecord(value: record.value.get(), time: $times.now().utc))
    except KeyError:
      error "No key, value or timeReceived in buffer", msg = msg, conn = conn
      return

  # Value sanitisation done. Start insertion process
  if not kad.config.validator.isValid(key, entryRecord):
    debug "Record is not valid", key, entryRecord
    return

  if not kad.isBestValue(key, entryRecord):
    error "Dropping received value, we have a better one"
    return

  kad.dataTable.insert(key, entryRecord.value, $times.now().utc)
  # consistent with following link, echo message without change
  # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
  try:
    await conn.writeLp(msg.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send find-node RPC reply", conn = conn, err = exc.msg
    return
