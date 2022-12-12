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
    onReservation: OnReservationHandler

proc reserveAndUpdate(self: AutoRelay, peerId: PeerId) {.async.} =
  while self.running:
    let
      rsvp = await self.client.reserve(peerId).wait(chronos.seconds(5))
      relayedAddr = MultiAddress.init("").tryGet() # TODO
#      relayedAddr = MultiAddress.init($(rsvp.addrs[0]) & "/p2p-circuit/p2p/" &
#                              $(switch.peerInfo.peerId).tryGet()
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

method innerRun(self: AutoRelay, switch: Switch) {.async, gcsafe.} =
  while true:
    # Remove peers that failed
    var peersToRemove: seq[PeerId]
    for k, v in self.peers:
      if v.failed():
        peersToRemove.add(k)
    for k in peersToRemove:
      self.peers.del(k)

    # Get all connected peers
    let rng = newRng()
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(RelayV2HopCodec in switch.peerStore[ProtoBook][it])
    rng.shuffle(connectedPeers)

    for peerId in switch.connectedPeers(Direction.Out):
      if self.peers.len() >= self.npeers:
        break
      if RelayV2HopCodec in switch.peerStore[ProtoBook][peerId]:
        self.peers[peerId] = self.reserveAndUpdate(peerId)
    let peersFutures = toSeq(self.peers.values())
    # await race(peersFutures) TODO

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

method new(T: typedesc[AutoRelay],
           npeers: int,
           client: RelayClient,
           onReservation: OnReservationHandler): T =
  T(npeers: npeers, client: client, onReservation: onReservation)
