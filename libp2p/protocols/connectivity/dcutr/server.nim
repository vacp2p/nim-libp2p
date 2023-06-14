# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[sets, sequtils]
import stew/[results, objects]
import chronos, chronicles

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch,
       ../../../utils/future

export DcutrError
export chronicles

type Dcutr* = ref object of LPProtocol

logScope:
  topics = "libp2p dcutr"

proc new*(T: typedesc[Dcutr], switch: Switch, connectTimeout = 15.seconds, maxDialableAddrs = 8): T =

  proc handleStream(stream: Connection, proto: string) {.async, gcsafe.} =
    var peerDialableAddrs: seq[MultiAddress]
    try:
      let connectMsg = DcutrMsg.decode(await stream.readLp(1024))
      debug "Dcutr receiver received a Connect message.", connectMsg

      var ourAddrs = switch.peerStore.getMostObservedProtosAndPorts() # likely empty when the peer is reachable
      if ourAddrs.len == 0:
        # this list should be the same as the peer's public addrs when it is reachable
        ourAddrs =  switch.peerInfo.listenAddrs.mapIt(switch.peerStore.guessDialableAddr(it))
      var ourDialableAddrs = getHolePunchableAddrs(ourAddrs)
      if ourDialableAddrs.len == 0:
        debug "Dcutr receiver has no supported dialable addresses. Aborting Dcutr.", ourAddrs
        return

      await stream.send(MsgType.Connect, ourAddrs)
      debug "Dcutr receiver has sent a Connect message back."
      let syncMsg = DcutrMsg.decode(await stream.readLp(1024))
      debug "Dcutr receiver has received a Sync message.", syncMsg

      peerDialableAddrs = getHolePunchableAddrs(connectMsg.addrs)
      if peerDialableAddrs.len == 0:
        debug "Dcutr initiator has no supported dialable addresses to connect to. Aborting Dcutr.", addrs=connectMsg.addrs
        return

      if peerDialableAddrs.len > maxDialableAddrs:
        peerDialableAddrs = peerDialableAddrs[0..<maxDialableAddrs]
      var futs = peerDialableAddrs.mapIt(switch.connect(stream.peerId, @[it], forceDial = true, reuseConnection = false, upgradeDir = Direction.In))
      try:
        discard await anyCompleted(futs).wait(connectTimeout)
        debug "Dcutr receiver has directly connected to the remote peer."
      finally:
        for fut in futs: fut.cancel()
    except CancelledError as err:
      raise err
    except AllFuturesFailedError as err:
      debug "Dcutr receiver could not connect to the remote peer, all connect attempts failed", peerDialableAddrs, msg = err.msg
      raise newException(DcutrError, "Dcutr receiver could not connect to the remote peer, all connect attempts failed", err)
    except AsyncTimeoutError as err:
      debug "Dcutr receiver could not connect to the remote peer, all connect attempts timed out", peerDialableAddrs, msg = err.msg
      raise newException(DcutrError, "Dcutr receiver could not connect to the remote peer, all connect attempts timed out", err)
    except CatchableError as err:
      warn "Unexpected error when Dcutr receiver tried to connect to the remote peer", msg = err.msg
      raise newException(DcutrError, "Unexpected error when Dcutr receiver tried to connect to the remote peer", err)

  let self = T()
  self.handler = handleStream
  self.codec = DcutrCodec
  self
