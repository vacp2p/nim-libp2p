{.used.}

import options, sequtils, strutils
import stew/byteutils, chronos
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
  teardown:
    checkTrackers()
  asyncTest "Simple local test":
    let
      rdv = RendezVous.new()
      s = createSwitch(rdv)

    await s.start()
    let res0 = rdv.requestLocally("empty")
    check res0.len == 0
    await rdv.advertise("foo")
    let res1 = rdv.requestLocally("foo")
    check:
      res1.len == 1
      res1[0] == s.peerInfo.signedPeerRecord.data
    let res2 = rdv.requestLocally("bar")
    check res2.len == 0
    rdv.unsubscribeLocally("foo")
    let res3 = rdv.requestLocally("foo")
    check res3.len == 0
    await s.stop()

  asyncTest "Simple remote test":
    let
      rdv = RendezVous.new()
      client = createSwitch(rdv)
      remoteSwitch = createSwitch()

    await client.start()
    await remoteSwitch.start()
    await client.connect(remoteSwitch.peerInfo.peerId, remoteSwitch.peerInfo.addrs)
    let res0 = await rdv.request("empty")
    check res0.len == 0
    await rdv.advertise("foo")
    let res1 = await rdv.request("foo")
    check:
      res1.len == 1
      res1[0] == client.peerInfo.signedPeerRecord.data
    let res2 = await rdv.request("bar")
    check res2.len == 0
    await rdv.unsubscribe("foo")
    let res3 = await rdv.request("foo")
    check res3.len == 0
    await allFutures(client.stop(), remoteSwitch.stop())

  asyncTest "Harder remote test":
    var
      rdvSeq: seq[RendezVous] = @[]
      clientSeq: seq[Switch] = @[]
      remoteSwitch = createSwitch()

    for x in 0..10:
      rdvSeq.add(RendezVous.new())
      clientSeq.add(createSwitch(rdvSeq[^1]))
    await remoteSwitch.start()
    await allFutures(clientSeq.mapIt(it.start()))
    await allFutures(clientSeq.mapIt(remoteSwitch.connect(it.peerInfo.peerId, it.peerInfo.addrs)))
    await allFutures(rdvSeq.mapIt(it.advertise("foo")))
    var data = clientSeq.mapIt(it.peerInfo.signedPeerRecord.data)
    let res1 = await rdvSeq[0].request("foo", 5)
    check res1.len == 5
    for d in res1:
      check d in data
    data.keepItIf(it notin res1)
    let res2 = await rdvSeq[0].request("foo")
    check res2.len == 5
    for d in res2:
      check d in data
    let res3 = await rdvSeq[0].request("foo")
    check res3.len == 0
    await remoteSwitch.stop()
    await allFutures(clientSeq.mapIt(it.stop()))

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
    check:
      res2.len == 1
      res2[0] == clientB.peerInfo.signedPeerRecord.data
    await allFutures(clientA.stop(), clientB.stop(), remoteSwitch.stop())

  asyncTest "Various local error":
    let
      rdv = RendezVous.new()
      switch = createSwitch(rdv)
    expect RendezVousError: discard await rdv.request("A".repeat(300))
    expect RendezVousError: discard await rdv.request("A", -1)
    expect RendezVousError: discard await rdv.request("A", 3000)
    expect RendezVousError: await rdv.advertise("A".repeat(300))
    expect RendezVousError: await rdv.advertise("A", 2.weeks)
    expect RendezVousError: await rdv.advertise("A", 5.minutes)
