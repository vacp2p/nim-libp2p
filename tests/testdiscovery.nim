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
  teardown:
    checkTrackers()
  asyncTest "RendezVous test":
    let
      rdvA = RendezVous.new()
      rdvB = RendezVous.new()
      clientA = createSwitch(rdvA)
      clientB = createSwitch(rdvB)
      remoteNode = createSwitch()
      doneAdvBar = newFuture[void]()
    var
      dm = DiscoveryManager()
      filters: DiscoveryFilter
    filters[RdvNamespace] = RdvNamespace("foo")
    dm.add(RendezVousInterface(rdv: rdvA))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await rdvB.advertise("foo")
    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

    proc manageQuery() {.async.} =
      await sleepAsync(500.milliseconds)
      # make sure to wait for the advertise to be done
      let query = dm.request(filters)
      let res = await query.getPeer()
      check:
        res.peerId == clientB.peerInfo.peerId
      doneAdvBar.complete()
    asyncSpawn manageQuery()
    await doneAdvBar
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
