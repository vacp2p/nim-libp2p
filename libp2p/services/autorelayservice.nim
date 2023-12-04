# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, chronicles, times, tables, sequtils
import ../switch,
       ../protocols/connectivity/relay/[client, utils]

logScope:
  topics = "libp2p autorelay"

type
  OnReservationHandler = proc (addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

  AutoRelayService* = ref object of Service
    running: bool
    runner: Future[void]
    client: RelayClient
    numRelays: int
    relayPeers: Table[PeerId, Future[void]]
    relayAddresses: Table[PeerId, seq[MultiAddress]]
    backingOff: seq[PeerId]
    peerAvailable: AsyncEvent
    onReservation: OnReservationHandler
    addressMapper: AddressMapper
    rng: ref HmacDrbgContext

proc isRunning*(self: AutoRelayService): bool =
  return self.running

proc addressMapper(
  self: AutoRelayService,
  listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
  return concat(toSeq(self.relayAddresses.values))

proc reserveAndUpdate(self: AutoRelayService, relayPid: PeerId, switch: Switch) {.async.} =
  while self.running:
    let
      rsvp = await self.client.reserve(relayPid).wait(chronos.seconds(5))
      relayedAddr = rsvp.addrs.mapIt(
        MultiAddress.init($it & "/p2p-circuit").tryGet())
      ttl = rsvp.expire.int64 - times.now().utc.toTime.toUnix
    if ttl <= 60:
      # A reservation under a minute is basically useless
      break
    if relayPid notin self.relayAddresses or self.relayAddresses[relayPid] != relayedAddr:
      self.relayAddresses[relayPid] = relayedAddr
      await switch.peerInfo.update()
      debug "Updated relay addresses", relayPid, relayedAddr
      if not self.onReservation.isNil():
        self.onReservation(concat(toSeq(self.relayAddresses.values)))
    await sleepAsync chronos.seconds(ttl - 30)

method setup*(self: AutoRelayService, switch: Switch): Future[bool] {.async.} =
  self.addressMapper = proc (listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
    return await addressMapper(self, listenAddrs)

  let hasBeenSetUp = await procCall Service(self).setup(switch)
  if hasBeenSetUp:
    proc handlePeerJoined(peerId: PeerId, event: PeerEvent) {.async.} =
      trace "Peer Joined", peerId
      if self.relayPeers.len < self.numRelays:
        self.peerAvailable.fire()
    proc handlePeerLeft(peerId: PeerId, event: PeerEvent) {.async.} =
      trace "Peer Left", peerId
      self.relayPeers.withValue(peerId, future):
        future[].cancel()
    switch.addPeerEventHandler(handlePeerJoined, Joined)
    switch.addPeerEventHandler(handlePeerLeft, Left)
    switch.peerInfo.addressMappers.add(self.addressMapper)
    await self.run(switch)
  return hasBeenSetUp

proc manageBackedOff(self: AutoRelayService, pid: PeerId) {.async.} =
  await sleepAsync(chronos.seconds(5))
  self.backingOff.keepItIf(it != pid)
  self.peerAvailable.fire()

proc innerRun(self: AutoRelayService, switch: Switch) {.async.} =
  while true:
    # Remove relayPeers that failed
    let peers = toSeq(self.relayPeers.keys())
    for k in peers:
      if self.relayPeers[k].finished():
        self.relayPeers.del(k)
        self.relayAddresses.del(k)
        if not self.onReservation.isNil():
          self.onReservation(concat(toSeq(self.relayAddresses.values)))
        # To avoid ddosing our peers in certain conditions
        self.backingOff.add(k)
        asyncSpawn self.manageBackedOff(k)

    # Get all connected relayPeers
    self.peerAvailable.clear()
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(RelayV2HopCodec in switch.peerStore[ProtoBook][it] and
                            it notin self.relayPeers and
                            it notin self.backingOff)
    self.rng.shuffle(connectedPeers)

    for relayPid in connectedPeers:
      if self.relayPeers.len() >= self.numRelays:
        break
      self.relayPeers[relayPid] = self.reserveAndUpdate(relayPid, switch)

    if self.relayPeers.len() > 0:
      await one(toSeq(self.relayPeers.values())) or self.peerAvailable.wait()
    else:
      await self.peerAvailable.wait()
      await sleepAsync(200.millis)

method run*(self: AutoRelayService, switch: Switch) {.async.} =
  if self.running:
    trace "Autorelay is already running"
    return
  self.running = true
  self.runner = self.innerRun(switch)

method stop*(self: AutoRelayService, switch: Switch): Future[bool] {.async.} =
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    self.running = false
    self.runner.cancel()
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    await switch.peerInfo.update()
  return hasBeenStopped

proc getAddresses*(self: AutoRelayService): seq[MultiAddress] =
  result = concat(toSeq(self.relayAddresses.values))

proc new*(T: typedesc[AutoRelayService],
          numRelays: int,
          client: RelayClient,
          onReservation: OnReservationHandler,
          rng: ref HmacDrbgContext): T =
  T(numRelays: numRelays,
    client: client,
    onReservation: onReservation,
    peerAvailable: newAsyncEvent(),
    rng: rng)
