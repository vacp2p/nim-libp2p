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
    check:
      res1.len == 1
      res1[0] == s.peerInfo.signedPeerRecord.data
    let res2 = rdv.requestLocally("bar")
    check res2.len == 0

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
    check:
      res1.len == 1
      res1[0] == client.peerInfo.signedPeerRecord.data
