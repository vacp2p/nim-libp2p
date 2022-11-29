# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos

import unittest2
import ./helpers
import ../libp2p/[builders,
                  switch,
                  services/hpservice,
                  services/autonatservice,
                  protocols/rendezvous]
import ../libp2p/protocols/connectivity/relay/[relay, client]
import ../libp2p/protocols/connectivity/autonat
import ../libp2p/discovery/[rendezvousinterface, discoverymngr]

proc createSwitch(rdv: RendezVous = nil, relay: Relay = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()

  if (rdv != nil):
    builder = builder.withRendezVous(rdv)

  if (relay != nil):
    builder = builder.withCircuitRelay(relay)

  return builder.build()

type
  AutonatStub = ref object of Autonat
    returnSuccess*: bool

method dialMe*(
  self: AutonatStub,
  pid: PeerId,
  addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.async.} =
    if self.returnSuccess:
      return MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    else:
      raise newException(AutonatError, "")

suite "Hope Punching":
  teardown:
    checkTrackers()

  asyncTest "Hope Punching Public Reachability test":
    let rdv = RendezVous.new()
    let relayClient = RelayClient.new()
    let switch1 = createSwitch(rdv, relayClient)

    let switch2 = createSwitch()
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let autonatService = AutonatService.new(Autonat.new(switch1))
    let hpservice = HPService.new(rdv, relayClient, autonatService)

    switch1.addService(hpservice)

    proc f(ma: MultiAddress) {.gcsafe, async.} =
      echo "onNewRelayAddr shouldn't be called"
      fail()

    hpservice.onNewRelayAddr(f)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await sleepAsync(1.seconds)

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Hope Punching Full Reachability test":

    let rdv1 = RendezVous.new()
    let rdv2 = RendezVous.new()

    let relayClient = RelayClient.new()
    let switch1 = createSwitch(rdv1, relayClient)
    let switch2 = createSwitch(rdv2)
    let switch3 = createSwitch()
    let switch4 = createSwitch()

    let bootRdv = RendezVous.new()
    let bootNode = createSwitch(rdv = bootRdv)
    await bootNode.start()

    let relay = Relay.new()
    let relayRdv = RendezVous.new()
    let relaySwitch = createSwitch(rdv = relayRdv, relay = relay)
    await relaySwitch.start()

    await relaySwitch.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)

    let dm = DiscoveryManager()
    dm.add(RendezVousInterface.new(relayRdv))
    dm.advertise(RdvNamespace("relay"))

    let autonatStub = AutonatStub.new()
    autonatStub.returnSuccess = false

    let autonatService = AutonatService.new(autonatStub)
    let hpservice = HPService.new(rdv1, relayClient, autonatService)

    switch1.addService(hpservice)
    await switch1.start()

    proc f(ma: MultiAddress) {.gcsafe, async.} =
      autonatStub.returnSuccess = true
      let expected = MultiAddress.init($relaySwitch.peerInfo.addrs[0] & "/p2p/" &
                            $relaySwitch.peerInfo.peerId & "/p2p-circuit/p2p/" &
                            $switch1.peerInfo.peerId).get()
      check ma == expected

    hpservice.onNewRelayAddr(f)

    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    await sleepAsync(1.seconds)

    await hpservice.run(switch1)

    await sleepAsync(1.seconds)

    echo switch1.peerInfo.addrs[0]
    await sleepAsync(1.seconds)

    await allFuturesThrowing(
      bootNode.stop(), relaySwitch.stop(), switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())