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

import std/[options, sets, sequtils]

import stew/[results, objects]
import chronos, chronicles

import core
import ../../protocol,
       ../../../stream/connection,
       ../../../switch

export chronicles

type Dcutr* = ref object of LPProtocol

logScope:
  topics = "libp2p dcutr"

proc new*(T: typedesc[Dcutr], switch: Switch): T =

  proc handleStream(stream: Connection, proto: string) {.async, gcsafe.} =
    try:
      let connectMsg = DcutrMsg.decode(await stream.readLp(1024))
      debug "Dcutr receiver received a Connect message.", connectMsg

      var ourAddrs = switch.peerStore.getMostObservedProtosAndPorts() # likely empty when the peer is reachable
      if ourAddrs.len == 0:
        # this list should be the same as the peer's public addrs when it is reachable
        ourAddrs =  switch.peerInfo.listenAddrs.mapIt(switch.peerStore.guessDialableAddr(it))
      var ourDialableAddrs = getTCPAddrs(ourAddrs)
      if ourDialableAddrs.len == 0:
        debug "Dcutr receiver has no supported dialable addresses. Aborting Dcutr."
        return

      await sendConnectMsg(stream, ourAddrs)
      debug "Dcutr receiver has sent a Connect message back."
      let syncMsg = DcutrMsg.decode(await stream.readLp(1024))
      debug "Dcutr receiver has received a Sync message.", syncMsg

      var peerDialableAddrs = getTCPAddrs(connectMsg.addrs)
      if peerDialableAddrs.len == 0:
        debug "DDcutr initiator has no supported dialable addresses to connect to. Aborting Dcutr."
        return

      await switch.connect(stream.peerId, peerDialableAddrs, forceDial = true, reuseConnection = false)
      debug "Dcutr receiver has directly connected to the remote peer."
    except CatchableError as err:
      error "Unexpected error in dcutr handler", msg = err.msg
      raise newException(DcutrError, "Unexpected error when trying a direct conn", err)

  let self = T()
  self.handler = handleStream
  self.codec = DcutrCodec
  self
