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
    switch,
    builders,
    discovery/discoverymngr,
    discovery/rendezvousinterface,
  ]
import ./helpers, ./asyncunit, ./utils/async, ./utils/assertions

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
  const
    namespace = "foo"
    rdvNamespace = RdvNamespace(namespace)

  var
    rdvA {.threadvar.}: RendezVous
    rdvB {.threadvar.}: RendezVous
    rdvRemote {.threadvar.}: RendezVous
    clientA {.threadvar.}: Switch
    clientB {.threadvar.}: Switch
    remoteNode {.threadvar.}: Switch
    dmA {.threadvar.}: DiscoveryManager
    dmB {.threadvar.}: DiscoveryManager

  asyncSetup:
    rdvA = RendezVous.new()
    rdvB = RendezVous.new()
    rdvRemote = RendezVous.new()
    clientA = createSwitch(rdvA)
    clientB = createSwitch(rdvB)
    remoteNode = createSwitch(rdvRemote)
    dmA = DiscoveryManager()
    dmB = DiscoveryManager()

    dmA.add(RendezVousInterface.new(rdvA, ttr = 500.milliseconds))
    dmB.add(RendezVousInterface.new(rdvB))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

  asyncTeardown:
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
    checkTrackers()

  asyncTest "RendezVous test":
    dmB.advertise(rdvNamespace)

    let
      query = dmA.request(rdvNamespace)
      res = await query.getPeer()
    check:
      res{PeerId}.get() == clientB.peerInfo.peerId
      res[PeerId] == clientB.peerInfo.peerId
      res.getAll(PeerId) == @[clientB.peerInfo.peerId]
      toHashSet(res.getAll(MultiAddress)) == toHashSet(clientB.peerInfo.addrs)

  asyncTest "Subscribe and unsubscribe":
    dmB.advertise(rdvNamespace)
    let
      query1 = dmA.request(rdvNamespace)
      res1 = await query1.getPeer().waitForResult(1.seconds)

    res1.assertIsOk()
    check res1.value{PeerId}.get() == clientB.peerInfo.peerId

    await rdvB.unsubscribe(namespace)
    var
      query2 = dmA.request(rdvNamespace)
      res2 = await query2.getPeer().waitForResult(1.seconds)

    res2.assertIsErr()

  asyncTest "Frequent sub/desub":
    for i in 0 ..< 10:
      dmB.advertise(rdvNamespace)
      let
        query1 = dmA.request(rdvNamespace)
        res1 = await query1.getPeer().waitForResult(1.seconds)

      res1.assertIsOk()
      check res1.value{PeerId}.get() == clientB.peerInfo.peerId

      await rdvB.unsubscribe(namespace)
      var
        query2 = dmA.request(rdvNamespace)
        res2 = await query2.getPeer().waitForResult(1.seconds)

      res2.assertIsErr()
