# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils

import results
import chronos, chronicles

import core
import
  ../../protocol, ../../../stream/connection, ../../../switch, ../../../utils/future

export DcutrError

type DcutrClient* = ref object
  connectTimeout: Duration
  maxDialableAddrs: int

logScope:
  topics = "libp2p dcutrclient"

proc new*(
    T: typedesc[DcutrClient], connectTimeout = 15.seconds, maxDialableAddrs = 8
): T =
  return T(connectTimeout: connectTimeout, maxDialableAddrs: maxDialableAddrs)

proc startSync*(
    self: DcutrClient, switch: Switch, remotePeerId: PeerId, addrs: seq[MultiAddress]
) {.async: (raises: [DcutrError, CancelledError]).} =
  logScope:
    peerId = switch.peerInfo.peerId

  var
    peerDialableAddrs: seq[MultiAddress]
    stream: Stream
  try:
    var ourDialableAddrs = getHolePunchableAddrs(addrs)
    if ourDialableAddrs.len == 0:
      debug "Dcutr initiator has no supported dialable addresses. Aborting Dcutr.",
        addrs
      return

    stream = await switch.dial(remotePeerId, DcutrCodec)
    await stream.send(MsgType.Connect, addrs)
    debug "Dcutr initiator has sent a Connect message."
    let rttStart = Moment.now()
    let connectAnswer = DcutrMsg.decode(await stream.readLp(1024)).valueOr:
      raise newException(DcutrError, error)

    peerDialableAddrs = getHolePunchableAddrs(connectAnswer.addrs)
    if peerDialableAddrs.len == 0:
      debug "Dcutr receiver has no supported dialable addresses to connect to. Aborting Dcutr.",
        addrs = connectAnswer.addrs
      return

    let rttEnd = Moment.now()
    debug "Dcutr initiator has received a Connect message back.", connectAnswer
    let halfRtt = (rttEnd - rttStart) div 2'i64

    # Expected DCUtR connections bypass ConnManager limits.
    debug "Dcutr initiator registering expected incoming connection",
      remotePeerId = stream.peerId
    let expectedIncoming = switch.connManager.expectDcutrConnection(stream.peerId, In)
    defer:
      expectedIncoming.cancelSoon()

    await stream.send(MsgType.Sync, @[])
    debug "Dcutr initiator has sent a Sync message."
    await sleepAsync(halfRtt)

    if peerDialableAddrs.len > self.maxDialableAddrs:
      peerDialableAddrs = peerDialableAddrs[0 ..< self.maxDialableAddrs]
    debug "Dcutr initiator starting direct dial attempts",
      peerDialableAddrs, connectTimeout = self.connectTimeout
    let dialFuts = peerDialableAddrs.mapIt(
      switch.connect(
        stream.peerId,
        @[it],
        forceDial = true,
        reuseConnection = false,
        dir = Direction.In,
      )
    )
    var futs = dialFuts
    futs.add(waitExpectedConnection(expectedIncoming))
    debug "Dcutr initiator waiting for direct dial or incoming connection",
      attempts = futs.len
    try:
      try:
        discard await anyCompleted(futs).wait(self.connectTimeout)
      except AsyncTimeoutError as err:
        if dialFuts.allIt(it.finished and not it.completed()):
          raise newException(AllFuturesFailedError, "all direct dial attempts failed")
        raise err
      debug "Dcutr initiator has directly connected to the remote peer."
    finally:
      debug "Dcutr initiator cancelling remaining direct dial attempts",
        attempts = futs.len
      await futs.cancelAndWait()
      debug "Dcutr initiator finished direct dial cleanup"
  except CancelledError as err:
    raise err
  except AllFuturesFailedError as err:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts failed",
      peerDialableAddrs, description = err.msg
    raise newException(
      DcutrError,
      "Dcutr initiator could not connect to the remote peer, all connect attempts failed",
      err,
    )
  except AsyncTimeoutError as err:
    debug "Dcutr initiator could not connect to the remote peer, all connect attempts timed out",
      peerDialableAddrs, description = err.msg
    raise newException(
      DcutrError,
      "Dcutr initiator could not connect to the remote peer, all connect attempts timed out",
      err,
    )
  except CatchableError as err:
    debug "Unexpected error when Dcutr initiator tried to connect to the remote peer",
      description = err.msg
    raise newException(
      DcutrError,
      "Unexpected error when Dcutr initiator tried to connect to the remote peer: " &
        err.msg,
      err,
    )
  finally:
    if stream != nil:
      await stream.close()
