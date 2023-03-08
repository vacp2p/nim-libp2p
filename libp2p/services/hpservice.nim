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

import std/tables
import ../switch, ../wire
import ../protocols/rendezvous
import ../services/autorelayservice
import ../discovery/[rendezvousinterface, discoverymngr]
import ../protocols/connectivity/relay/relay
import ../protocols/connectivity/autonat/service
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

proc startDirectConn(self: HPService, switch: Switch, peerId: PeerId): Future[bool] {.async.} =
  let conn = switch.connManager.selectMuxer(peerId).connection
  await sleepAsync(100.milliseconds) # wait for AddressBook to be populated
  if isRelayed(conn):
    for address in switch.peerStore[AddressBook][peerId]:
      if self.isPublicIPAddr(initTAddress(address).get()):
        try:
          await switch.connect(peerId, @[address], true, false)
          await conn.close()
          debug "direct connection started"
          return true
        except CatchableError as exc:
          debug "failed to start direct connection", exc = exc.msg
          continue
  return false

method setup*(self: HPService, switch: Switch): Future[bool] {.async.} =
  var hasBeenSetup = await procCall Service(self).setup(switch)
  hasBeenSetup = hasBeenSetup and await self.autonatService.setup(switch)

  if hasBeenSetup:
    self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] {.async.} =
      if await self.startDirectConn(switch, peerId):
        return

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

# proc onNewRelayAddr*(self: HPService, f: Callb) =
#   self.callb = f
