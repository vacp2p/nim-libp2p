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

  AutoRelay* = ref object of Service
    running: bool
    runner: Future[void]
    client: RelayClient
    npeers: int
    peers: Table[PeerId, Future[void]]
    peerJoined: AsyncEvent
    onReservation: OnReservationHandler

proc reserveAndUpdate(self: AutoRelay, relayPid: PeerId, selfPid: PeerId) {.async.} =
  while self.running:
    let
      rsvp = await self.client.reserve(relayPid).wait(chronos.seconds(5))
      relayedAddr = MultiAddress.init($(rsvp.addrs[0]) &
                                  "/p2p-circuit/p2p/" &
                                  $selfPid).tryGet()
    await self.onReservation(relayedAddr)
    await sleepAsync chronos.seconds(rsvp.expire.int64 - times.now().utc.toTime.toUnix)

method setup*(self: AutoRelay, switch: Switch) {.async, gcsafe.} =
  if self.inUse:
    warn "Autorelay setup has already been called"
    return
  self.inUse = true
  proc handlePeer(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == Left and peerId in self.peers:
      self.peers[peerId].cancel()
    elif event.kind == Joined and self.peers.len < self.npeers:
      self.peerJoined.fire()
  switch.addPeerEventHandler(handlePeer, Joined)
  switch.addPeerEventHandler(handlePeer, Left)

method innerRun(self: AutoRelay, switch: Switch) {.async, gcsafe.} =
  while true:
    # Remove peers that failed
    var peersToRemove: seq[PeerId]
    for k, v in self.peers:
      if v.failed() or v.cancelled():
        peersToRemove.add(k)
    for k in peersToRemove:
      self.peers.del(k)
    if peersToRemove.len() > 0:
      await sleepAsync(500.millis) # To avoid ddosing our peers in certain condition

    # Get all connected peers
    let rng = newRng()
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(RelayV2HopCodec in switch.peerStore[ProtoBook][it])
    rng.shuffle(connectedPeers)

    for relayPid in switch.connectedPeers(Direction.Out):
      if self.peers.len() >= self.npeers:
        break
      if RelayV2HopCodec in switch.peerStore[ProtoBook][relayPid]:
        self.peers[relayPid] = self.reserveAndUpdate(relayPid, switch.peerInfo.peerId)
    let peersFutures = toSeq(self.peers.values())

    if self.peers.len() < self.npeers:
      self.peerJoined.clear()
      await one(peersFutures) or self.peerJoined.wait()
    else:
      discard await one(peersFutures)

method run*(self: AutoRelay, switch: Switch) {.async, gcsafe.} =
  if self.running:
    trace "Autorelay is already running"
    return
  self.running = true
  self.runner = self.innerRun(switch)

method stop*(self: AutoRelay, switch: Switch) {.async, gcsafe.} =
  if not self.inUse:
    warn "service is already stopped"
  self.inUse = false
  self.running = false
  self.runner.cancel()

proc new*(T: typedesc[AutoRelay],
          npeers: int,
          client: RelayClient,
          onReservation: OnReservationHandler): T =
  T(npeers: npeers,
    client: client,
    onReservation: onReservation,
    peerJoined: newAsyncEvent())
