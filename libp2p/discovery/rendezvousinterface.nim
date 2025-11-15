# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import ./discoverymngr
import ../protocols/rendezvous
import ../utils/heartbeat
import ../[peerid, routing_record]

type
  RendezVousInterface* = ref object of DiscoveryInterface
    rdv*: RendezVous
    timeToRequest: Duration
    timeToAdvertise: Duration
    ttl: Duration

  RdvNamespace* = string

method request*(
    self: RendezVousInterface, pa: PeerAttributes
) {.async: (raises: [DiscoveryError, CancelledError]).} =
  var namespace = Opt.none(string)

  for attr in pa:
    if attr.ofType(RdvNamespace):
      namespace = Opt.some(string attr.to(RdvNamespace))
    elif attr.ofType(PeerId):
      namespace = Opt.some($attr.to(PeerId))
    else:
      # unhandled type
      return

  heartbeat "Requesting peer attributes", self.timeToRequest:
    let peerRecords: seq[PeerRecord] =
      await self.rdv.request(namespace, Opt.none(int), Opt.none(seq[PeerId]))

    for pr in peerRecords:
      var peer: PeerAttributes
      peer.add(pr.peerId)
      for address in pr.addresses:
        peer.add(address.address)

      peer.add(RdvNamespace(namespace.get()))
      self.onPeerFound(peer)

method advertise*(
    self: RendezVousInterface
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  while true:
    var toAdvertise: seq[string]
    for attr in self.toAdvertise:
      if attr.ofType(RdvNamespace):
        toAdvertise.add string attr.to(RdvNamespace)
      elif attr.ofType(PeerId):
        toAdvertise.add $attr.to(PeerId)

    self.advertisementUpdated.clear()
    for toAdv in toAdvertise:
      try:
        await self.rdv.advertise(toAdv, Opt.some(self.ttl))
      except CatchableError as error:
        debug "RendezVous advertise error: ", description = error.msg

    await sleepAsync(self.timeToAdvertise) or self.advertisementUpdated.wait()

proc new*(
    T: typedesc[RendezVousInterface],
    rdv: RendezVous,
    ttr: Duration = 1.minutes,
    tta: Duration = 1.minutes,
    ttl: Duration = MinimumDuration,
): RendezVousInterface =
  T(rdv: rdv, timeToRequest: ttr, timeToAdvertise: tta, ttl: ttl)
