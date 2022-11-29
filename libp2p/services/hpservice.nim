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

import ../switch
import chronos
import std/tables
import ../protocols/rendezvous
import ../services/autonatservice
import ../discovery/[rendezvousinterface, discoverymngr]
import ../protocols/connectivity/relay/[relay, client]

type
  HPService* = ref object of Service
    rdv: RendezVous
    dm: DiscoveryManager
    relayClient: RelayClient
    autonatService: AutonatService
    onNewStatusHandler: NewStatusHandler
    callb: Callb

  Callb* = proc (ma: MultiAddress): Future[void]  {.gcsafe, raises: [Defect].}

proc new*(T: typedesc[HPService], rdv: RendezVous, relayClient: RelayClient, autonatService: AutonatService): T =
  let dm = DiscoveryManager()
  dm.add(RendezVousInterface.new(rdv))
  return T(
    rdv: rdv,
    dm: dm,
    relayClient: relayClient,
    autonatService: autonatService)

proc relay(self: HPService) {.async.} =
  let queryRelay = self.dm.request(RdvNamespace("relay"))
  let res = await queryRelay.getPeer()
  let rsvp = await self.relayClient.reserve(res[PeerId], res.getAll(MultiAddress))
  let relayedAddr = MultiAddress.init($rsvp.addrs[0] &
                              "/p2p-circuit/p2p/" &
                              $rsvp.voucher.get().reservingPeerId).tryGet()

  await self.callb(relayedAddr)

  # switch1.peerInfo.listenAddrs = @[relayedAddr]
  # await switch1.peerInfo.update()

# proc networkReachability*(self: HPService): NetworkReachability {.inline.} =
#   return self.networkReachability

method setup*(self: HPService, switch: Switch) {.async.} =
  await self.autonatService.setup(switch)

  self.onNewStatusHandler = proc (networkReachability: NetworkReachability) {.gcsafe, async.} =
    if networkReachability == NetworkReachability.Private:
      await self.relay()

  self.autonatService.onNewStatuswithMaxConfidence(self.onNewStatusHandler)

method run*(self: HPService, switch: Switch) {.async, public.} =
  await self.autonatService.run(switch)

method stop*(self: HPService, switch: Switch) {.async, public.} =
  await self.autonatService.stop(switch)
  if not isNil(self.onNewStatusHandler):
    discard #switch.connManager.removePeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)

proc onNewRelayAddr*(self: HPService, f: Callb) =
  self.callb = f
