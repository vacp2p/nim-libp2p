# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[tables, sequtils]

import chronos, chronicles

import ../switch, ../wire
import ../protocols/rendezvous
import ../services/autorelayservice
import ../protocols/connectivity/relay/relay
import ../protocols/connectivity/autonat/service
import ../protocols/connectivity/dcutr/[client, server]
import ../multicodec

logScope:
  topics = "libp2p hpservice"

type
  HPService* = ref object of Service
    newConnectedPeerHandler: PeerEventHandler
    onNewStatusHandler: StatusAndConfidenceHandler
    autoRelayService: AutoRelayService
    autonatService: AutonatService
    isPublicIPAddrProc: IsPublicIPAddrProc

  IsPublicIPAddrProc* = proc(ta: TransportAddress): bool {.gcsafe, raises: [].}

proc new*(T: typedesc[HPService], autonatService: AutonatService, autoRelayService: AutoRelayService,
          isPublicIPAddrProc: IsPublicIPAddrProc = isGlobal): T =
  return T(autonatService: autonatService, autoRelayService: autoRelayService, isPublicIPAddrProc: isPublicIPAddrProc)

proc tryStartingDirectConn(self: HPService, switch: Switch, peerId: PeerId): Future[bool] {.async.} =
  proc tryConnect(address: MultiAddress): Future[bool] {.async.} =
    debug "Trying to create direct connection", peerId, address
    await switch.connect(peerId, @[address], true, false)
    debug "Direct connection created."
    return true

  await sleepAsync(500.milliseconds) # wait for AddressBook to be populated
  for address in switch.peerStore[AddressBook][peerId]:
    try:
      let isRelayed = address.contains(multiCodec("p2p-circuit"))
      if isRelayed.isErr() or isRelayed.get():
        continue
      if DNS.matchPartial(address):
        return await tryConnect(address)
      else:
        let ta = initTAddress(address)
        if ta.isOk() and self.isPublicIPAddrProc(ta.get()):
          return await tryConnect(address)
    except CatchableError as err:
      debug "Failed to create direct connection.", err = err.msg
      continue
  return false

proc closeRelayConn(relayedConn: Connection) {.async.} =
  await sleepAsync(2000.milliseconds) # grace period before closing relayed connection
  await relayedConn.close()

proc newConnectedPeerHandler(self: HPService, switch: Switch, peerId: PeerId, event: PeerEvent) {.async.} =
  try:
    # Get all connections to the peer. If there is at least one non-relayed connection, return.
    let connections = switch.connManager.getConnections()[peerId].mapIt(it.connection)
    if connections.anyIt(not isRelayed(it)):
      return
    let incomingRelays = connections.filterIt(it.transportDir == Direction.In)
    if incomingRelays.len == 0:
      return

    let relayedConn = incomingRelays[0]

    if await self.tryStartingDirectConn(switch, peerId):
      await closeRelayConn(relayedConn)
      return

    let dcutrClient = DcutrClient.new()
    var natAddrs = switch.peerStore.getMostObservedProtosAndPorts()
    if natAddrs.len == 0:
      natAddrs =  switch.peerInfo.listenAddrs.mapIt(switch.peerStore.guessDialableAddr(it))
    await dcutrClient.startSync(switch, peerId, natAddrs)
    await closeRelayConn(relayedConn)
  except CatchableError as err:
    debug "Hole punching failed during dcutr", err = err.msg

method setup*(self: HPService, switch: Switch): Future[bool] {.async.} =
  var hasBeenSetup = await procCall Service(self).setup(switch)
  hasBeenSetup = hasBeenSetup and await self.autonatService.setup(switch)

  if hasBeenSetup:
    let dcutrProto = Dcutr.new(switch)
    switch.mount(dcutrProto)

    self.newConnectedPeerHandler = proc (peerId: PeerId, event: PeerEvent) {.async.} =
      await newConnectedPeerHandler(self, switch, peerId, event)

    switch.connManager.addPeerEventHandler(self.newConnectedPeerHandler, PeerEventKind.Joined)

    self.onNewStatusHandler = proc (networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
      if networkReachability == NetworkReachability.NotReachable and not self.autoRelayService.isRunning():
        discard await self.autoRelayService.setup(switch)
      elif networkReachability == NetworkReachability.Reachable and self.autoRelayService.isRunning():
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
