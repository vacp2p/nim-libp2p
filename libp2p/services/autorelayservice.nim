# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import chronos, chronicles, times, tables, sequtils
import ../[multicodec, switch, wire], ../protocols/connectivity/relay/[client, utils]

logScope:
  topics = "libp2p autorelay"

type
  OnReservationHandler* = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

  AutoRelayService* = ref object of Service
    running: bool
    runner: Future[void]
    client: RelayClient
    maxNumRelays: int # maximum number of relays we can reserve at the same time
    relayPeers: Table[PeerId, Future[void]]
    relayAddresses: Table[PeerId, seq[MultiAddress]]
    backingOff: Table[PeerId, Future[void]]
    peerAvailable: AsyncEvent
    onReservation: OnReservationHandler
    addressMapper: AddressMapper
    rng: Rng

proc isRunning*(self: AutoRelayService): bool =
  return self.running

func stillProduced(
    manager: AddressManager, address: MultiAddress, produced: seq[MultiAddress]
): bool =
  ## The candidate table still holds the last pass: a chain address this pass dropped is gone.
  address in produced or not manager.isChainProduced(address)

func confirmedIpFamilies(
    manager: AddressManager, produced: seq[MultiAddress]
): set[IpAddressFamily] =
  ## A confirmed private address proves only LAN reachability, so it stays out.
  var families: set[IpAddressFamily]
  for address in manager.confirmedAddrs():
    if not manager.stillProduced(address, produced):
      continue
    if address.contains(multiCodec("p2p-circuit")).get(false):
      continue
    if not address.isPublicMA():
      continue
    let ip = address.getIp().valueOr:
      continue
    families.incl(ip.family)
  families

func stillNeeded(relayAddr: MultiAddress, confirmed: set[IpAddressFamily]): bool =
  ## A relay address is redundant once a direct address of its IP family is confirmed.
  let ip = relayAddr.getIp().valueOr:
    return true
  ip.family notin confirmed

proc addressMapper(
    self: AutoRelayService, switch: Switch, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: []).} =
  let confirmed = switch.addressManager.confirmedIpFamilies(listenAddrs)
  let relayAddrs =
    concat(toSeq(self.relayAddresses.values)).filterIt(it.stillNeeded(confirmed))
  return relayAddrs & listenAddrs

proc reserveAndUpdate(
    self: AutoRelayService, relayPid: PeerId, switch: Switch
) {.async: (raises: [CatchableError]).} =
  # CatchableError used to simplify raised errors here, as there could be 
  # many different errors raised but caller don't really care what is cause of error
  while self.running:
    let
      rsvp = await self.client.reserve(relayPid).wait(chronos.seconds(5))
      relayedAddr = rsvp.addrs.mapIt(MultiAddress.init($it & "/p2p-circuit").tryGet())
      ttl = rsvp.expire.int64 - times.now().utc.toTime.toUnix
    if ttl <= 60:
      # A reservation under a minute is basically useless
      break
    if relayPid notin self.relayAddresses or self.relayAddresses[relayPid] != relayedAddr:
      self.relayAddresses[relayPid] = relayedAddr
      await switch.peerInfo.update()
      debug "Updated relay addresses", relayPid, relayedAddr
      if self.running and not self.onReservation.isNil():
        self.onReservation(concat(toSeq(self.relayAddresses.values)))
    await sleepAsync chronos.seconds(ttl - 30)

method setup*(self: AutoRelayService, switch: Switch) {.raises: [].} =
  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    return await addressMapper(self, switch, listenAddrs)

  proc handlePeerIdentified(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    trace "Peer Identified", peerId
    if self.relayPeers.len < self.maxNumRelays:
      self.peerAvailable.fire()

  proc handlePeerLeft(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    trace "Peer Left", peerId
    self.relayPeers.withValue(peerId, future):
      future[].cancelSoon()

  switch.addPeerEventHandler(handlePeerIdentified, Identified)
  switch.addPeerEventHandler(handlePeerLeft, Left)

proc manageBackedOff(
    self: AutoRelayService, pid: PeerId
) {.async: (raises: [CancelledError]).} =
  await sleepAsync(chronos.seconds(5))
  self.backingOff.del(pid)
  self.peerAvailable.fire()

proc innerRun(
    self: AutoRelayService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  while self.running:
    # Remove relayPeers that failed
    let peers = toSeq(self.relayPeers.keys())
    for k in peers:
      try:
        if self.relayPeers[k].finished():
          self.relayPeers.del(k)
          self.relayAddresses.del(k)
          if self.running and not self.onReservation.isNil():
            self.onReservation(concat(toSeq(self.relayAddresses.values)))
          # To avoid ddosing our peers in certain conditions
          self.backingOff[k] = self.manageBackedOff(k)
      except KeyError:
        raiseAssert "checked with in"

    # Get all connected relayPeers
    self.peerAvailable.clear()
    var connectedPeers = switch.connectedPeers(Direction.Out)
    connectedPeers.keepItIf(
      RelayV2HopCodec in switch.peerStore[ProtoBook][it] and it notin self.relayPeers and
        it notin self.backingOff
    )
    self.rng.shuffle(connectedPeers)

    for relayPid in connectedPeers:
      if self.relayPeers.len() >= self.maxNumRelays:
        break
      self.relayPeers[relayPid] = self.reserveAndUpdate(relayPid, switch)

    if self.relayPeers.len() > 0:
      try:
        await one(toSeq(self.relayPeers.values())) or self.peerAvailable.wait()
      except ValueError:
        raiseAssert "checked with relayPeers.len()"
    else:
      await self.peerAvailable.wait()

method start*(
    self: AutoRelayService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  if self.running:
    return
  self.running = true
  switch.addressManager.addMapper(self.addressMapper, AddrSource.Circuit)
  await switch.peerInfo.update()
  self.runner = self.innerRun(switch)

method stop*(
    self: AutoRelayService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  if not self.running:
    return
  self.running = false
  self.runner.cancelSoon()
  for fut in self.backingOff.values:
    fut.cancelSoon()
  self.backingOff.clear()
  switch.addressManager.removeMapper(self.addressMapper)
  await switch.peerInfo.update()

proc getAddresses*(self: AutoRelayService): seq[MultiAddress] =
  concat(toSeq(self.relayAddresses.values))

proc new*(
    T: typedesc[AutoRelayService],
    maxNumRelays: int,
    client: RelayClient,
    onReservation: OnReservationHandler,
    rng: Rng,
): T =
  T(
    maxNumRelays: maxNumRelays,
    client: client,
    onReservation: onReservation,
    peerAvailable: newAsyncEvent(),
    rng: rng,
  )
