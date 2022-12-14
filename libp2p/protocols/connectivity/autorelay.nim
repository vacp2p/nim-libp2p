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
  OnReservationHandler = proc (ma: MultiAddress): Future[void] {.gcsafe, raises: [Defect].}

  AutoRelayService* = ref object of Service
    running: bool
    runner: Future[void]
    client: RelayClient
    numRelays: int
    relayPeers: Table[PeerId, Future[void]]
    relayAddresses: Table[PeerId, MultiAddress]
    peerJoined: AsyncEvent
    onReservation: OnReservationHandler

proc reserveAndUpdate(self: AutoRelayService, relayPid: PeerId, selfPid: PeerId) {.async.} =
  while self.running:
    let
      rsvp = await self.client.reserve(relayPid).wait(chronos.seconds(5))
      relayedAddr = MultiAddress.init($(rsvp.addrs[0]) &
                                  "/p2p-circuit/p2p/" &
                                  $selfPid).tryGet()
    if not self.onReservation.isNil():
      await self.onReservation(relayedAddr)
    self.relayAddresses[relayPid] = relayedAddr
    await sleepAsync chronos.seconds(rsvp.expire.int64 - times.now().utc.toTime.toUnix)

method setup*(self: AutoRelayService, switch: Switch): Future[bool] {.async, gcsafe.} =
  let hasBeenSetUp = await procCall Service(self).setup(switch)
  if hasBeenSetUp:
    proc handlePeerJoined(peerId: PeerId, event: PeerEvent) {.async.} =
      if self.relayPeers.len < self.numRelays:
        self.peerJoined.fire()
    proc handlePeerLeft(peerId: PeerId, event: PeerEvent) {.async.} =
      if peerId in self.relayPeers:
        self.relayPeers[peerId].cancel()
    switch.addPeerEventHandler(handlePeerJoined, Joined)
    switch.addPeerEventHandler(handlePeerLeft, Left)
  return hasBeenSetUp

method innerRun(self: AutoRelayService, switch: Switch) {.async, gcsafe.} =
  while true:
    # Remove relayPeers that failed
    var peersToRemove: seq[PeerId]
    for k, v in self.relayPeers:
      if v.finished():
        peersToRemove.add(k)
    for k in peersToRemove:
      self.relayPeers.del(k)
      self.relayAddresses.del(k)
    if peersToRemove.len() > 0:
      await sleepAsync(500.millis) # To avoid ddosing our relayPeers in certain condition

    # Get all connected relayPeers
    let rng = newRng()
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(RelayV2HopCodec in switch.peerStore[ProtoBook][it] or
                            it notin self.relayPeers)
    rng.shuffle(connectedPeers)

    for relayPid in connectedPeers:
      if self.relayPeers.len() >= self.numRelays:
        break
      if RelayV2HopCodec in switch.peerStore[ProtoBook][relayPid]:
        self.relayPeers[relayPid] = self.reserveAndUpdate(relayPid, switch.peerInfo.peerId)
    let peersFutures = toSeq(self.relayPeers.values())

    if self.relayPeers.len() < self.numRelays:
      self.peerJoined.clear()
      await one(peersFutures) or self.peerJoined.wait()
    else:
      discard await one(peersFutures)

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

method getAddresses*(self: AutoRelayService): seq[MultiAddress] =
  result = toSeq(self.relayAddresses.values)

proc new*(T: typedesc[AutoRelayService],
          numRelays: int,
          client: RelayClient,
          onReservation: OnReservationHandler): T =
  T(numRelays: numRelays,
    client: client,
    onReservation: onReservation,
    peerJoined: newAsyncEvent())
