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
  DcutrClient* = ref object of RootObj

logScope:
  topics = "libp2p dcutrclient"

proc new*(T: typedesc[DcutrClient]): T =
  return T()

proc sendSyncMsg(stream: Connection, addrs: seq[MultiAddress]) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Sync, addrs: addrs).encode()
  await stream.writeLp(pb.buffer)

proc startSync*(self: DcutrClient, switch: Switch, remotePeerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
  logScope:
    peerId = switch.peerInfo.peerId

  var stream: Connection
  try:
    stream = await switch.dial(remotePeerId, DcutrCodec)
    await sendConnectMsg(stream, addrs)
    debug "Dcutr initiator has sent a Connect message."
    let rttStart = Opt.some(Moment.now())
    let connectAnswer = DcutrMsg.decode(await stream.readLp(1024))
    let rttEnd = Opt.some(Moment.now())
    debug "Dcutr initiator has received a Connect message back.", connectAnswer
    let halfRtt = (rttEnd.get() - rttStart.get()) div 2
    await sendSyncMsg(stream, addrs)
    debug "Dcutr initiator has sent a Sync message."
    await sleepAsync(halfRtt)
    await switch.connect(remotePeerId, connectAnswer.addrs, forceDial = true, reuseConnection = false, upgradeDir = Direction.In)
    debug "Dcutr initiator has directly connected to the remote peer."
  except CatchableError as err:
    error "Unexpected error when trying direct conn", err = err.msg
    raise newException(DcutrError, "Unexpected error when trying a direct conn", err)
  finally:
    if stream != nil:
      await stream.close()

