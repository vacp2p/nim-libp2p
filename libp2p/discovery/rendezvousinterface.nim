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

import sequtils
import chronos
import ./discoveryinterface,
       ../protocols/rendezvous,
       ../peerid

type
  #TODO should take default TTL as a param
  RendezVousInterface* = ref object of DiscoveryInterface
    rdv*: RendezVous

  RdvNamespace* = distinct string

proc `==`*(a: RdvNamespace, b: RdvNamespace): bool {.borrow.}

method request*(self: RendezVousInterface, filters: DiscoveryFilters) {.async.} =
  var namespace = ""
  for filter in filters:
    if filter.ofType(RdvNamespace):
      namespace = string filter.to(RdvNamespace)
    elif filter.ofType(DiscoveryService):
      namespace = string filter.to(DiscoveryService)
    elif filter.ofType(PeerId):
      namespace = $filter.to(PeerId)
    else:
      # unhandled type
      return
  while true:
    for pr in await self.rdv.request(namespace):
      var peer: DiscoveryFilters
      peer.add(pr.peerId)
      for address in pr.addresses:
        peer.add(address)

      peer.add(pr)
      peer.add(DiscoveryService(namespace))
      peer.add(RdvNamespace(namespace))
      self.onPeerFound(peer)

    #TODO should be configurable
    await sleepAsync(1.minutes)

method advertise*(self: RendezVousInterface) {.async.} =
  while true:
    var toAdvertise: seq[string]
    for filter in self.toAdvertise:
      if filter.ofType(RdvNamespace):
        toAdvertise.add string filter.to(RdvNamespace)
      elif filter.ofType(DiscoveryService):
        toAdvertise.add string filter.to(DiscoveryService)
      elif filter.ofType(PeerId):
        toAdvertise.add $filter.to(PeerId)

    self.advertisementUpdated.clear()
    for toAdv in toAdvertise:
      await self.rdv.advertise(toAdv)

    #TODO put TTL here
    await sleepAsync(10.hours) or self.advertisementUpdated.wait()
