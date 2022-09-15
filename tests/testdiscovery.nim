{.used.}

import options, chronos
import stew/byteutils
import ../libp2p/[protocols/rendezvous,
                  switch,
                  builders,
                  discovery/discoverymngr,
                  discovery/rendezvousinterface,]
import ./helpers

proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withRendezVous(rdv)
    .build()

suite "Discovery":
  asyncTest "RendezVous test":
    let
      rdvA = RendezVous.new()
      rdvB = RendezVous.new()
      clientA = createSwitch(rdvA)
      clientB = createSwitch(rdvB)
      remoteNode = createSwitch()
      doneAdvFoo = newFuture[void]()
      doneAdvBar = newFuture[void]()
    var
      dm = DiscoveryManager()
      filters: DiscoveryFilter
    filters[RdvNamespace] = RdvNamespace("foo")
    dm.add(RendezVousInterface(rdv: rdvA))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

    proc manageQuery() {.async.} =
      let query = dm.request(filters)
      await doneAdvFoo
      let res = await query.getPeer()
      check:
        res.peerId == clientB.peerInfo.peerId
      doneAdvBar.complete()
    asyncSpawn manageQuery()
    await rdvB.advertise("foo")
    doneAdvFoo.complete()
    await doneAdvBar
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
