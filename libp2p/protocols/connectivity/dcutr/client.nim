# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/sequtils

import stew/results
import chronos, chronicles

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch,
       ../../../utils/future

export DcutrError

type
  DcutrClient* = ref object
    connectTimeout: Duration
    maxDialableAddrs: int

logScope:
  topics = "libp2p dcutrclient"

proc new*(T: typedesc[DcutrClient], connectTimeout = 15.seconds, maxDialableAddrs = 8): T =
  return T(connectTimeout: connectTimeout, maxDialableAddrs: maxDialableAddrs)

proc startSync*(self: DcutrClient, switch: Switch, remotePeerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
  logScope:
    peerId = switch.peerInfo.peerId

  var
    peerDialableAddrs: seq[MultiAddress]
    stream: Connection
  try:
    var ourDialableAddrs = getHolePunchableAddrs(addrs)
    if ourDialableAddrs.len == 0:
      debug "Dcutr initiator has no supported dialable addresses. Aborting Dcutr.", addrs
      return

    stream = await switch.dial(remotePeerId, DcutrCodec)
    await stream.send(MsgType.Connect, addrs)
    debug "Dcutr initiator has sent a Connect message."
    let rttStart = Moment.now()
    let connectAnswer = DcutrMsg.decode(await stream.readLp(1024))

    peerDialableAddrs = getHolePunchableAddrs(connectAnswer.addrs)
    if peerDialableAddrs.len == 0:
      debug "Dcutr receiver has no supported dialable addresses to connect to. Aborting Dcutr.", addrs=connectAnswer.addrs
      return

    let rttEnd = Moment.now()
    debug "Dcutr initiator has received a Connect message back.", connectAnswer
    let halfRtt = (rttEnd - rttStart) div 2'i64
    await stream.send(MsgType.Sync, @[])
    debug "Dcutr initiator has sent a Sync message."
    await sleepAsync(halfRtt)

    if peerDialableAddrs.len > self.maxDialableAddrs:
        peerDialableAddrs = peerDialableAddrs[0..<self.maxDialableAddrs]
    var futs = peerDialableAddrs.mapIt(switch.connect(stream.peerId, @[it], forceDial = true, reuseConnection = false, dir = Direction.In))
    try:
      discard await anyCompleted(futs).wait(self.connectTimeout)
      debug "Dcutr initiator has directly connected to the remote peer."
    finally:
      for fut in futs: fut.cancel()
  except CancelledError as err:
    raise err
  except AllFuturesFailedError as err:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts failed", peerDialableAddrs, msg = err.msg
    raise newException(DcutrError, "Dcutr initiator could not connect to the remote peer, all connect attempts failed", err)
  except AsyncTimeoutError as err:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts timed out", peerDialableAddrs, msg = err.msg
    raise newException(DcutrError, "Dcutr initiator could not connect to the remote peer, all connect attempts timed out", err)
  except CatchableError as err:
    debug "Unexpected error when Dcutr initiator tried to connect to the remote peer", err = err.msg
    raise newException(DcutrError, "Unexpected error when Dcutr initiator tried to connect to the remote peer", err)
  finally:
    if stream != nil:
      await stream.close()

