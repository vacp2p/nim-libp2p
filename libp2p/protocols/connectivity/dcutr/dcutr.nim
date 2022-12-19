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

logScope:
  topics = "libp2p dcutr"

const
  DcutrCodec* = "/libp2p/dcutr/1.0.0"

type
  DcutrError* = object of LPError

  Dcutr* = ref object of LPProtocol
    switch*: Switch

method new*(T: typedesc[Dcutr]) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    discard

  let d = T()

  d.handler = handleStream
  d.codec = DcutrCodec

proc sendConnectMsg(conn: Connection, pid: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Connect, addrs: addrs).encode()
  await conn.writeLp(pb.buffer)

proc connect*(a: Dcutr, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.async.} =
  let conn =
    try:
      if addrs.len == 0:
        await a.switch.dial(pid, @[DcutrCodec])
      else:
        await a.switch.dial(pid, addrs, DcutrCodec)
    except CatchableError as err:
      raise newException(DcutrError, "Unexpected error when dialling", err)
  defer: await conn.close()
  await conn.sendConnectMsg(a.switch.peerInfo.peerId, a.switch.peerInfo.addrs)