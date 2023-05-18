# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
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

import chronos
import ./discoverymngr,
       ../protocols/rendezvous,
       ../peerid

type
  RendezVousInterface* = ref object of DiscoveryInterface
    rdv*: RendezVous
    timeToRequest: Duration
    timeToAdvertise: Duration

  RdvNamespace* = distinct string

proc `==`*(a, b: RdvNamespace): bool {.borrow.}

method request*(self: RendezVousInterface, pa: PeerAttributes) {.async.} =
  var namespace = ""
  for attr in pa:
    if attr.ofType(RdvNamespace):
      namespace = string attr.to(RdvNamespace)
    elif attr.ofType(DiscoveryService):
      namespace = string attr.to(DiscoveryService)
    elif attr.ofType(PeerId):
      namespace = $attr.to(PeerId)
    else:
      # unhandled type
      return
  while true:
    for pr in await self.rdv.request(namespace):
      var peer: PeerAttributes
      peer.add(pr.peerId)
      for address in pr.addresses:
        peer.add(address.address)

      peer.add(DiscoveryService(namespace))
      peer.add(RdvNamespace(namespace))
      self.onPeerFound(peer)

    await sleepAsync(self.timeToRequest)

method advertise*(self: RendezVousInterface) {.async.} =
  while true:
    var toAdvertise: seq[string]
    for attr in self.toAdvertise:
      if attr.ofType(RdvNamespace):
        toAdvertise.add string attr.to(RdvNamespace)
      elif attr.ofType(DiscoveryService):
        toAdvertise.add string attr.to(DiscoveryService)
      elif attr.ofType(PeerId):
        toAdvertise.add $attr.to(PeerId)

    self.advertisementUpdated.clear()
    for toAdv in toAdvertise:
      await self.rdv.advertise(toAdv, self.timeToAdvertise)

    await sleepAsync(self.timeToAdvertise) or self.advertisementUpdated.wait()

proc new*(T: typedesc[RendezVousInterface],
          rdv: RendezVous,
          ttr: Duration = 1.minutes,
          tta: Duration = MinimumDuration): RendezVousInterface =
  T(rdv: rdv, timeToRequest: ttr, timeToAdvertise: tta)
