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

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch

import stew/[results, objects]
import chronos, chronicles

export chronicles

type Dcutr* = ref object of LPProtocol
 switch: Switch

logScope:
  topics = "libp2p dcutr"

proc new*(T: typedesc[Dcutr], switch: Switch): T =
  let self = T(switch: switch)
  proc handleStream(stream: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msg = DcutrMsg.decode(await stream.readLp(1024))
      trace "Sync receiver received a Connect message.", msg
      case msg.msgType:
        of MsgType.Connect:
          await sendConnectMsg(stream, self.switch.peerInfo.addrs)
          trace "Sync receiver has sent a Connect message back"
        of MsgType.Sync:
          trace "Sync receiver has received a Sync message"
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