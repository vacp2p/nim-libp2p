# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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

import std/[options, sets, sequtils]
import ../../protocol,
       ../../../switch,
       ../../../stream/connection
import messages
import stew/results
import chronos, chronicles, stew/objects

export chronicles

logScope:
  topics = "libp2p dcutr"

const
  DcutrCodec* = "/libp2p/dcutr/1.0.0"

type
  DcutrError* = object of LPError

  Dcutr* = ref object of LPProtocol
    switch*: Switch
    rttStart: Option[Moment]
    rttEnd: Option[Moment]

proc sendConnectMsg(self: Dcutr, conn: Connection, pid: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Connect, addrs: addrs).encode()
  await conn.writeLp(pb.buffer)

proc sendSyncMsg(self: Dcutr, conn: Connection) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Sync, addrs: @[]).encode()
  await conn.writeLp(pb.buffer)

proc startSync*(self: Dcutr, conn: Connection): Future[Connection] {.async.} =
  self.rttStart = some(Moment.now())
  trace "Sending a Connect msg", conn
  await self.sendConnectMsg(conn, self.switch.peerInfo.peerId, self.switch.peerInfo.addrs)
  let connectAnswer = DcutrMsg.decode(await conn.readLp(1024))
  trace "Received a Connect msg back", conn
  self.rttEnd = some(Moment.now())
  trace "Sending a Sync msg", conn
  await self.sendSyncMsg(conn)
  let halfRtt = (self.rttEnd.get() - self.rttStart.get())
  await sleepAsync(halfRtt)
  let directConn =
    try:
      await self.switch.dial(conn.peerId, connectAnswer.addrs, DcutrCodec)
    except CatchableError as err:
      raise newException(DcutrError, "Unexpected error when dialling", err)
  return directConn

proc new*(T: typedesc[Dcutr], switch: Switch): T =
  let self = T(switch: switch, rttStart: none(Moment), rttEnd: none(Moment))
  proc handleStream(stream: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msg = DcutrMsg.decode(await stream.readLp(1024))
      case msg.msgType:
        of MsgType.Connect:
          #trace "Received a Connect msg", msg
          trace "Sending a Connect msg back", msg
          await self.sendConnectMsg(stream, self.switch.peerInfo.peerId, self.switch.peerInfo.addrs)
        of MsgType.Sync:
          let directConn =
            try:
              await self.switch.dial(stream.peerId, msg.addrs, DcutrCodec)
            except CatchableError as err:
              raise newException(DcutrError, "Unexpected error when dialling", err)
          await directConn.writeLp("hi")
    except CatchableError as exc:
      error "Unexpected error in dcutr handler", msg = exc.msg
    finally:
      trace "exiting dcutr handler", stream
      await stream.close()

  self.handler = handleStream
  self.codec = DcutrCodec
  self

proc connect*(self: Dcutr, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.async.} =
  let conn =
    try:
      if addrs.len == 0:
        await self.switch.dial(pid, @[DcutrCodec])
      else:
        await self.switch.dial(pid, addrs, DcutrCodec)
    except CatchableError as err:
      raise newException(DcutrError, "Unexpected error when dialling", err)
  defer: await conn.close()
  await self.sendConnectMsg(conn, self.switch.peerInfo.peerId, self.switch.peerInfo.addrs)