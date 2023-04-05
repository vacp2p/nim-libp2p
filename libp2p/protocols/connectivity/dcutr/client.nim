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

import std/sequtils

import stew/results
import chronos, chronicles

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch,
       ../../../utils/future

type
  DcutrClient* = ref object of RootObj
    connectTimeout: Duration
    maxDialableAddrs: int

logScope:
  topics = "libp2p dcutrclient"

proc new*(T: typedesc[DcutrClient], connectTimeout = 15.seconds, maxDialableAddrs = 8): T =
  return T(connectTimeout: connectTimeout, maxDialableAddrs: maxDialableAddrs)

proc sendSyncMsg(stream: Connection, addrs: seq[MultiAddress]) {.async.} =
  let pb = DcutrMsg(msgType: MsgType.Sync, addrs: addrs).encode()
  await stream.writeLp(pb.buffer)

proc startSync*(self: DcutrClient, switch: Switch, remotePeerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
  logScope:
    peerId = switch.peerInfo.peerId

  var
    peerDialableAddrs: seq[MultiAddress]
    stream: Connection
  try:
    var ourDialableAddrs = getTCPAddrs(addrs)
    if ourDialableAddrs.len == 0:
      debug "Dcutr initiator has no supported dialable addresses. Aborting Dcutr."
      return

    stream = await switch.dial(remotePeerId, DcutrCodec)
    await sendConnectMsg(stream, addrs)
    debug "Dcutr initiator has sent a Connect message."
    let rttStart = Moment.now()
    let connectAnswer = DcutrMsg.decode(await stream.readLp(1024))

    peerDialableAddrs = getTCPAddrs(connectAnswer.addrs)
    if peerDialableAddrs.len == 0:
      debug "DDcutr receiver has no supported dialable addresses to connect to. Aborting Dcutr."
      return

    let rttEnd = Moment.now()
    debug "Dcutr initiator has received a Connect message back.", connectAnswer
    let halfRtt = (rttEnd - rttStart) div 2'i64
    echo halfRtt.type
    await sendSyncMsg(stream, addrs)
    debug "Dcutr initiator has sent a Sync message."
    await sleepAsync(halfRtt)

    if peerDialableAddrs.len > self.maxDialableAddrs:
        peerDialableAddrs = peerDialableAddrs[0..<self.maxDialableAddrs]
    var futs = peerDialableAddrs.mapIt(switch.connect(stream.peerId, @[it], forceDial = true, reuseConnection = false, upgradeDir = Direction.In))
    let fut = await anyCompleted(futs).wait(self.connectTimeout)
    await fut
    if fut.completed():
      debug "Dcutr initiator has directly connected to the remote peer."
    else:
      debug "Dcutr initiator could not connect to the remote peer.", msg = fut.error.msg
  except CancelledError as exc:
    raise exc
  except AllFuturesFailedError as exc:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts failed", peerDialableAddrs, msg = exc.msg
  except AsyncTimeoutError as exc:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts timed out", peerDialableAddrs, msg = exc.msg
  except CatchableError as err:
    warn "Unexpected error when trying direct conn", err = err.msg
    raise newException(DcutrError, "Unexpected error when trying a direct conn", err)
  finally:
    if stream != nil:
      await stream.close()

