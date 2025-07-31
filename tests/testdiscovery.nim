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
import
  ../libp2p/[
    protocols/rendezvous,
    protocols/kademlia,
    switch,
    builders,
    discovery/discoverymngr,
    discovery/rendezvousinterface,
    discovery/discoverykad,
  ]
import ./helpers, ./utils/async_tests

proc createDSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()
proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init(MemoryAutoAddress).tryGet()])
  .withMemoryTransport()
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

  asyncTest "Kad test":
    let clientA = createDSwitch()
    let clientB = createDSwitch()
    let kadA = KadDHT.new(clientA)
    let kadB = KadDHT.new(clientB)
    let remoteNode = createDSwitch()
    let dmA = DiscoveryManager()
    let dmB = DiscoveryManager()
    clientA.mount(kadA)
    clientB.mount(kadB)
    let kda: KadDiscovery = KadDiscovery.new(kadA)
    dmA.add(kda)
    dmB.add(KadDiscovery.new(kadB))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

    # dmB.advertise(KadNamespace("hardcoded"))

    let
      # TODO: this calls the unimplemented base, but I want to call the inherited method...
      query = dmA.request(KadNamespace("hardcoded"))
      res = await query.getPeer()
    check:
      res{PeerId}.get() == clientB.peerInfo.peerId
      res[PeerId] == clientB.peerInfo.peerId
      res.getAll(PeerId) == @[clientB.peerInfo.peerId]
      toHashSet(res.getAll(MultiAddress)) == toHashSet(clientB.peerInfo.addrs)
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
