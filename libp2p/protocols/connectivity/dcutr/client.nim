# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch

import stew/results
import chronos, chronicles

type
  DcutrClient* = ref object of LPProtocol
    rttStart: Opt[Moment]
    rttEnd: Opt[Moment]

logScope:
  topics = "libp2p dcutrclient"

proc new*(T: typedesc[DcutrClient]): T =
  return T(rttStart: Opt.none(Moment), rttEnd: Opt.none(Moment))

proc sendSyncMsg(conn: Connection) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Sync, addrs: @[]).encode()
  await conn.writeLp(pb.buffer)

proc startSync*(self: DcutrClient, switch: Switch, conn: Connection): Future[Connection] {.async.} =
  logScope:
    peerId = switch.peerInfo.peerId

  self.rttStart = Opt.some(Moment.now())
  trace "Sync initiator has sent a Connect message", conn
  await sendConnectMsg(conn, switch.peerInfo.addrs)
  let connectAnswer = DcutrMsg.decode(await conn.readLp(1024))
  trace "Sync initiator has received a Connect message back", conn
  self.rttEnd = Opt.some(Moment.now())
  trace "Sending a Sync message", conn
  await sendSyncMsg(conn)
  let halfRtt = (self.rttEnd.get() - self.rttStart.get()) div 2
  await sleepAsync(halfRtt)
  let directConn =
    try:
      await switch.dial(conn.peerId, connectAnswer.addrs, DcutrCodec)
    except CatchableError as err:
      raise newException(DcutrError, "Unexpected error when dialling", err)
  return directConn

proc connect*(switch: Switch, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.async.} =
  let conn =
    try:
      if addrs.len == 0:
        await switch.dial(pid, @[DcutrCodec])
      else:
        await switch.dial(pid, addrs, DcutrCodec)
    except CatchableError as err:
      raise newException(DcutrError, "Unexpected error when dialling", err)
  defer: await conn.close()
  await sendConnectMsg(conn, switch.peerInfo.addrs)
