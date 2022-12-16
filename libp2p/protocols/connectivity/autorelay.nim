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

import chronos, chronicles, times, tables, sequtils, options
import ../../switch,
       relay/[client, utils]

logScope:
  topics = "libp2p autorelay"

type
  OnReservationHandler = proc (addresses: seq[MultiAddress]) {.gcsafe, raises: [Defect].}

  AutoRelayService* = ref object of Service
    running: bool
    runner: Future[void]
    client: RelayClient
    numRelays: int
    relayPeers: Table[PeerId, Future[void]]
    relayAddresses: Table[PeerId, MultiAddress]
    backingOff: seq[PeerId]
    reservationFailed: AsyncEvent
    peerAvailable: AsyncEvent
    onReservation: OnReservationHandler
    rng: ref HmacDrbgContext

proc reserveAndUpdate(self: AutoRelayService, relayPid: PeerId, selfPid: PeerId) {.async.} =
  defer: self.reservationFailed.fire()
  while self.running:
    let
      rsvp = await self.client.reserve(relayPid).wait(chronos.seconds(5))
      relayedAddr = MultiAddress.init($(rsvp.addrs[0]) &
                                  "/p2p-circuit/p2p/" &
                                  $selfPid).tryGet()
      ttl = rsvp.expire.int64 - times.now().utc.toTime.toUnix
    if ttl <= 60:
      # A reservation under a minute is basically useless
      break
    if relayPid notin self.relayAddresses or self.relayAddresses[relayPid] != relayedAddr:
      self.relayAddresses[relayPid] = relayedAddr
      if not self.onReservation.isNil():
        self.onReservation(toSeq(self.relayAddresses.values))
    await sleepAsync chronos.seconds(max(0, ttl - 30))

method setup*(self: AutoRelayService, switch: Switch): Future[bool] {.async, gcsafe.} =
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
  return hasBeenSetUp

proc manageBackedOff(self: AutoRelayService, pid: PeerId) {.async.} =
  await sleepAsync(chronos.seconds(5))
  self.backingOff.keepItIf(it != pid)
  self.peerAvailable.fire()

proc innerRun(self: AutoRelayService, switch: Switch) {.async, gcsafe.} =
  while true:
    # Remove relayPeers that failed
    let peers = toSeq(self.relayPeers.keys())
    for k in peers:
      if self.relayPeers[k].finished():
        self.relayPeers.del(k)
        self.relayAddresses.del(k)
        if not self.onReservation.isNil():
          self.onReservation(toSeq(self.relayAddresses.values))
        # To avoid ddosing our peers in certain conditions
        self.backingOff.add(k)
        asyncSpawn self.manageBackedOff(k)

    # Get all connected relayPeers
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(RelayV2HopCodec in switch.peerStore[ProtoBook][it] or
                            it notin self.relayPeers or
                            it notin self.backingOff)
    self.rng.shuffle(connectedPeers)

    for relayPid in connectedPeers:
      if self.relayPeers.len() >= self.numRelays:
        break
      self.relayPeers[relayPid] = self.reserveAndUpdate(relayPid, switch.peerInfo.peerId)
    let peersFutures = toSeq(self.relayPeers.values())

    self.reservationFailed.clear()
    self.peerAvailable.clear()
    if self.relayPeers.len() < self.numRelays:
      await self.reservationFailed.wait() or self.peerAvailable.wait()
    else:
      await self.reservationFailed.wait()

method run*(self: AutoRelayService, switch: Switch) {.async, gcsafe.} =
  if self.running:
    trace "Autorelay is already running"
    return
  self.running = true
  self.runner = self.innerRun(switch)

method stop*(self: AutoRelayService, switch: Switch): Future[bool] {.async, gcsafe.} =
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    self.running = false
    self.runner.cancel()
  return hasBeenStopped

proc getAddresses*(self: AutoRelayService): seq[MultiAddress] =
  result = toSeq(self.relayAddresses.values)

proc new*(T: typedesc[AutoRelayService],
          numRelays: int,
          client: RelayClient,
          onReservation: OnReservationHandler,
          rng: ref HmacDrbgContext): T =
  T(numRelays: numRelays,
    client: client,
    onReservation: onReservation,
    reservationFailed: newAsyncEvent(),
    peerAvailable: newAsyncEvent(),
    rng: rng)
