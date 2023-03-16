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

import std/[tables, sequtils]
import ../switch, ../wire
import ../protocols/rendezvous
import ../services/autorelayservice
import ../discovery/[rendezvousinterface, discoverymngr]
import ../protocols/connectivity/relay/relay
import ../protocols/connectivity/autonat/service
from ../protocols/connectivity/dcutr/core import DcutrError
import ../protocols/connectivity/dcutr/client
import chronos

logScope:
  topics = "libp2p hpservice"

type
  HPService* = ref object of Service
    newConnectedPeerHandler: PeerEventHandler
    onNewStatusHandler: StatusAndConfidenceHandler
    autoRelayService: AutoRelayService
    autonatService: AutonatService
    isPublicIPAddr: isPublicIPAddrFunc

  isPublicIPAddrFunc* = proc(ta: TransportAddress): bool {.gcsafe, raises: [Defect].}

proc new*(T: typedesc[HPService], autonatService: AutonatService, autoRelayService: AutoRelayService,
          isPublicIPAddr: isPublicIPAddrFunc = proc(ta: TransportAddress): bool = return true): T = # FIXME: use chronos
  return T(
    autonatService: autonatService,
    autoRelayService: autoRelayService,
    isPublicIPAddr: isPublicIPAddr)

proc tryStartingDirectConn(self: HPService, switch: Switch, peerId: PeerId): Future[bool] {.async.} =
  await sleepAsync(100.milliseconds) # wait for AddressBook to be populated
  for address in switch.peerStore[AddressBook][peerId]:
    if self.isPublicIPAddr(initTAddress(address).get()):
      try:
        await switch.connect(peerId, @[address], true, false)
        debug "direct connection created"
        return true
      except CatchableError as err:
        debug "failed to create direct connection", err = err.msg
        continue
  return false

proc guessNatAddrs(peerStore: PeerStore, addrs: seq[MultiAddress]): seq[MultiAddress] =
  for a in addrs:
    let guess = peerStore.replaceMAIpByMostObserved(a)
    if guess.isSome():
      result.add(guess.get())

method setup*(self: HPService, switch: Switch): Future[bool] {.async.} =
  var hasBeenSetup = await procCall Service(self).setup(switch)
  hasBeenSetup = hasBeenSetup and await self.autonatService.setup(switch)

  if hasBeenSetup:
    self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] {.async.} =
      try:
        let conn = switch.connManager.selectMuxer(peerId).connection
        if isRelayed(conn):
          if await self.tryStartingDirectConn(switch, peerId):
            await conn.close()
            return
          let dcutrClient = DcutrClient.new()
          var natAddrs = switch.peerStore.getMostObservedIPsAndPorts()
          if natAddrs.len == 0:
            natAddrs = guessDialableAddrs(switch.peerStore, switch.peerInfo.addrs)
          await dcutrClient.startSync(switch, peerId, natAddrs)
          await sleepAsync(2000.milliseconds) # grace period before closing relayed connection
          await conn.close()
      except DcutrError as err:
        error "Hole punching failed during dcutr", err = err.msg

    switch.connManager.addPeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)

    self.onNewStatusHandler = proc (networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable:
        discard await self.autoRelayService.setup(switch)
      elif networkReachability == NetworkReachability.Reachable:
        discard await self.autoRelayService.stop(switch)

      # We do it here instead of in the AutonatService because this is useful only when hole punching.
      for t in switch.transports:
        t.networkReachability = networkReachability

    self.autonatService.statusAndConfidenceHandler(self.onNewStatusHandler)
  return hasBeenSetup

method run*(self: HPService, switch: Switch) {.async, public.} =
  await self.autonatService.run(switch)

method stop*(self: HPService, switch: Switch): Future[bool] {.async, public.} =
  discard await self.autonatService.stop(switch)
  if not isNil(self.newConnectedPeerHandler):
    switch.connManager.removePeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)
