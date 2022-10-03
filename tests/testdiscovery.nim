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
    var
      dmA = DiscoveryManager()
      dmB = DiscoveryManager()
    dmA.add(RendezVousInterface.new(rdvA, ttr = 500.milliseconds))
    dmB.add(RendezVousInterface.new(rdvB))
    await allFutures(clientA.start(), clientB.start(), remoteNode.start())

    await clientB.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)
    await clientA.connect(remoteNode.peerInfo.peerId, remoteNode.peerInfo.addrs)

    dmB.advertise(RdvNamespace("foo"))

    let query = dmA.request(RdvNamespace("foo"))
    let res = await query.getPeer()
    let resPid = res[PeerId]
    check:
      resPid.len == 1 and resPid[0] == clientB.peerInfo.peerId
    await allFutures(clientA.stop(), clientB.stop(), remoteNode.stop())
