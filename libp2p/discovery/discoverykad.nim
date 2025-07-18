# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronicles
import chronos
import ./discoverymngr, ../protocols/kademlia, ../peerid

type
  KadDiscovery* = ref object of DiscoveryInterface
    kad*: KadDHT
    timeToRequest: Duration
    timeToAdvertise: Duration
    ttl: Duration

  KadNamespace* = distinct string

proc `==`*(a, b: KadNamespace): bool {.borrow.}

method request*(
    self: KadDiscovery, pa: PeerAttributes
) {.async: (raises: [DiscoveryError, CancelledError]).} =
  var namespace = Opt.none(string)
  for attr in pa:
    if attr.ofType(KadNamespace):
      namespace = Opt.some(string attr.to(KadNamespace))
    elif attr.ofType(DiscoveryService):
      namespace = Opt.some(string attr.to(DiscoveryService))
    elif attr.ofType(PeerId):
      namespace = Opt.some($attr.to(PeerId))
    else:
      # unhandled type
      return
  while true:
    for pr in await self.kad.request(namespace):
      var peer: PeerAttributes
      peer.add(pr.peerId)
      for address in pr.addresses:
        peer.add(address.address)

      peer.add(DiscoveryService(namespace.get()))
      peer.add(RdvNamespace(namespace.get()))
      self.onPeerFound(peer)

    await sleepAsync(self.timeToRequest)

method advertise*(
    self: KadDiscovery
) {.async: (raises: [CancelledError, AdvertiseError]).} =
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
      try:
        await self.kad.advertise(toAdv, self.ttl)
      except CatchableError as error:
        debug "Kad advertise error: ", description = error.msg

    await sleepAsync(self.timeToAdvertise) or self.advertisementUpdated.wait()

proc new*(
    T: typedesc[KadDiscovery],
    kad: KadDHT,
    ttr: Duration = 1.minutes,
    tta: Duration = 1.minutes,
    ttl: Duration = MinimumDuration,
): KadDiscovery =
  T(kad: kad, timeToRequest: ttr, timeToAdvertise: tta, ttl: ttl)
