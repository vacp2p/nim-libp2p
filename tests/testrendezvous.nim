{.used.}

import options, chronos
import stew/byteutils
import ../libp2p/[protocols/rendezvous,
                  switch,
                  builders,]
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

suite "RendezVous":
  asyncTest "Simple local test":
    let
      rdv = RendezVous.new()
      s = createSwitch(rdv)

    await s.start()
    await rdv.advertise("foo")
    let res1 = rdv.requestLocally("foo")
    check res1.len == 1 and res1[0] == s.peerInfo.signedPeerRecord.data
    let res2 = rdv.requestLocally("bar")
    check res2.len == 0
    rdv.unsubscribeLocally("foo")
    let res3 = rdv.requestLocally("foo")
    check res3.len == 0

  asyncTest "Simple remote test":
    let
      rdv = RendezVous.new()
      client = createSwitch(rdv)
      remoteSwitch = createSwitch()

    await client.start()
    await remoteSwitch.start()
    await client.connect(remoteSwitch.peerInfo.peerId, remoteSwitch.peerInfo.addrs)
    await rdv.advertise("foo")
    let res1 = await rdv.request("foo")
    check res1.len == 1 and res1[0] == client.peerInfo.signedPeerRecord.data
    let res2 = await rdv.request("bar")
    check res2.len == 0
    await rdv.unsubscribe("foo")
    let res3 = await rdv.request("foo")
    check res3.len == 0

  asyncTest "Simple cookie test":
    let
      rdvA = RendezVous.new()
      rdvB = RendezVous.new()
      clientA = createSwitch(rdvA)
      clientB = createSwitch(rdvB)
      remoteSwitch = createSwitch()

    await clientA.start()
    await clientB.start()
    await remoteSwitch.start()
    await clientA.connect(remoteSwitch.peerInfo.peerId, remoteSwitch.peerInfo.addrs)
    await clientB.connect(remoteSwitch.peerInfo.peerId, remoteSwitch.peerInfo.addrs)
    await rdvA.advertise("foo")
    let res1 = await rdvA.request("foo")
    await rdvB.advertise("foo")
    let res2 = await rdvA.request("foo")
    check: res2.len == 1 and res2[0] == clientB.peerInfo.signedPeerRecord.data
