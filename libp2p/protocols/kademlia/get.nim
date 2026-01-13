# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sets, times, tables, sequtils]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types, find, routingtable, put]

proc dispatchGetVal(
    kad: KadDHT, peer: PeerId, key: Key
): Future[(PeerId, Opt[EntryRecord], seq[PeerId])] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  var closerPeers: seq[PeerId] = @[]
  var entryRecord = Opt.none(EntryRecord)

  let conn =
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], KadCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.getValue, key: key)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    error "GetValue reply decode fail", error = error, conn = conn
    return

  for peer in reply.closerPeers:
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", peerId = peer.id, error = error
      continue

    kad.updatePeers(@[(p, peer.addrs)])
    closerPeers.add(p)

  conn.observedAddr.withValue(observedAddr):
    kad.updatePeers(@[PeerInfo(peerId: conn.peerId, addrs: @[observedAddr])])

  if reply.record.isSome:
    if reply.record.get().value.isSome:
      let value = reply.record.get().value.get()
      let time = reply.record.get().timeReceived.valueOr:
        debug "GetValue returned record with no timeReceived, using current time instead",
          msg = msg, reply = reply, conn = conn
        TimeStamp($times.now().utc)
      entryRecord = Opt.some(EntryRecord(value: value, time: time))
    else:
      debug "GetValue returned record with no value",
        msg = msg, reply = reply, conn = conn
  else:
    debug "GetValue returned empty record",
      peerId = conn.peerId, msg = msg, reply = reply, conn = conn

  return (peer, entryRecord, closerPeers)

proc bestValidRecord(
    kad: KadDHT, key: Key, currRec: EntryRecord, newRec: EntryRecord
): Result[int, string] =
  if not kad.config.validator.isValid(key, newRec):
    return ok(0)
  let selectedIdx = kad.config.selector.select(key, @[newRec]).valueOr:
    return err("Could not select best value")
  ok(selectedIdx)

proc getValue*(
    kad: KadDHT, key: Key, quorumOverride: Opt[int] = Opt.none(int)
): Future[Result[EntryRecord, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let quorum = quorumOverride.valueOr:
    kad.config.quorum

  var best: Opt[EntryRecord]
  var bestPeers: HashSet[PeerId] # Pb
  # if locally present
  if kad.dataTable.hasKey(key):
    let localRecord = kad.dataTable.get(key)
    if quorum <= 1:
      return ok(localRecord.get())
    best = localRecord
    bestPeers.incl(kad.switch.peerInfo.peerId)

  var candidates: CandidatePeers = @[] # Pn
  var outdatedPeers: HashSet[PeerId] #Po
  var queried: HashSet[PeerId] #Pq
  var rpcBatch: seq[
    Future[(PeerId, Opt[EntryRecord], seq[PeerId])].Raising(
      [CancelledError, DialFailedError, LPStreamError]
    )
  ] = @[]
  for p in kad.findClosestPeers(key, kad.config.alpha).toHashSet:
    let peerId = p.id.toPeerId().valueOr:
      continue
    candidates.add(peerId)
  block outerLoop:
    while true:
      if candidates.len == 0:
        break

      rpcBatch = @[]
      for c in candidates:
        rpcBatch.add(kad.dispatchGetVal(c, key))
        queried.incl(c)

      let deadline = Moment.now() + kad.config.timeout
      while rpcBatch.len != 0:
        if deadline - Moment.now() <= chronos.seconds(0):
          break

        var raceFut =
          try:
            await one(rpcBatch)
          except ValueError:
            raiseAssert "checked with rpcBatch.len"

        if raceFut.completed:
          rpcBatch.del(rpcBatch.find(raceFut))
          try:
            let (peer, optRecord, closestPeers) = await raceFut.wait(kad.config.timeout)
            if optRecord.isSome:
              if best.isNone:
                best = optRecord
                bestPeers.incl(peer)
                if (quorum == 0 and bestPeers.len > 0) or
                    (quorum > 0 and bestPeers.len >= quorum):
                  # Cancel other requests
                  for fut in rpcBatch:
                    if not fut.finished():
                      await fut.cancelAndWait()
                  break outerLoop
              else:
                if optRecord.get().value == best.get().value:
                  bestPeers.incl(peer)
                else:
                  let bestIdx = kad.bestValidRecord(key, best.get(), optRecord.get()).valueOr:
                    debug "could not validate or select record", err = error
                    continue

                  if bestIdx != 0:
                    outdatedPeers.incl(bestPeers)
                    best = optRecord
                    bestPeers.clear()
                    bestPeers.incl(peer)

                    if (quorum == 0 and bestPeers.len > 0) or
                        (quorum > 0 and bestPeers.len >= quorum):
                      # Cancel other requests
                      for fut in rpcBatch:
                        if not fut.finished():
                          await fut.cancelAndWait()
                      break outerLoop
                  else:
                    # new value is not the best
                    outdatedPeers.incl(peer)
            else:
              # No value
              outdatedPeers.incl(peer)

            var candidateKeys: seq[Key] = @[]
            for cp in closestPeers:
              if not queried.contains(cp):
                candidateKeys.add(cp.toKey())

            kad.rtable.sortByXorDistance(candidateKeys, key)
            candidates = candidateKeys
              .toHashSet()
              .toSeq()
              .mapIt(it.toPeerId().get())
              .filterIt(it != kad.switch.peerInfo.peerId)
          except AsyncTimeoutError, DialFailedError, LPStreamError:
            continue

  if best.isNone:
    return err("No record found")

  if bestPeers.len < quorum:
    return err(
      "Not enough valid records to achieve quorum, needed " & $quorum & " got " &
        $bestPeers.len
    )

  # insert value to our localtable
  kad.dataTable.insert(key, best.get().value, $times.now().utc)

  # update peers that
  # - don't have best value
  # - don't have valid records
  # - don't have the values at all
  var putRpcBatch =
    outdatedPeers.mapIt(kad.switch.dispatchPutVal(it, key, best.get().value))
  try:
    await putRpcBatch.allFutures().wait(chronos.seconds(5))
  except AsyncTimeoutError:
    # Dispatch will timeout if any of the calls don't receive a response (which is normal)
    discard

  ok(best.get())

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
