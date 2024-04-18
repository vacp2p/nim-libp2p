{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options, chronos, sets
import ../libp2p/[protocols/rendezvous,
                  switch,
                  builders,
                  discovery/discoverymngr,
                  discovery/rendezvousinterface,]
import ./helpers

proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder.new()
    .withRng(rng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withRendezVous(rdv)
    .build()

suite "Discovery":
  teardown:
    checkTrackers()
  asyncTest "RendezVous test":
    let
      rdvA = RendezVous.new()
      rdvB = RendezVous.new()
      clientA = createSwitch(rdvA)
      clientB = createSwitch(rdvB)
      remoteNode = createSwitch()
      dmA = DiscoveryManager()
      dmB = DiscoveryManager()
    dmA.add(RendezVousInterface.new(rdvA, ttr = 500.milliseconds))
    dmB.add(RendezVousInterface.new(rdvB))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

    dmB.advertise(RdvNamespace("foo"))

    let
      query = dmA.request(RdvNamespace("foo"))
      res = await query.getPeer()
    check:
      res{PeerId}.get() == clientB.peerInfo.peerId
      res[PeerId] == clientB.peerInfo.peerId
      res.getAll(PeerId) == @[clientB.peerInfo.peerId]
      toHashSet(res.getAll(MultiAddress)) == toHashSet(clientB.peerInfo.addrs)
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
