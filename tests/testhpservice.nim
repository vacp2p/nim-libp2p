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
                  services/autorelayservice]
import ../libp2p/protocols/connectivity/relay/[relay, client]
import ../libp2p/protocols/connectivity/autonat/[service]
import ../libp2p/wire
import stubs/autonatclientstub

proc isPublicAddrIPAddrMock*(ta: TransportAddress): bool =
  return true

proc createSwitch(r: Relay = nil, hpService: Service = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()

  if hpService != nil:
    builder = builder.withServices(@[hpService])

  if r != nil:
    builder = builder.withCircuitRelay(r)

  return builder.build()

proc buildRelayMA(switchRelay: Switch, switchClient: Switch): MultiAddress =
  MultiAddress.init($switchRelay.peerInfo.addrs[0] & "/p2p/" &
                    $switchRelay.peerInfo.peerId & "/p2p-circuit/p2p/" &
                    $switchClient.peerInfo.peerId).get()

suite "Hole Punching":
  teardown:
    checkTrackers()

  asyncTest "Direct connection must work when peer address is public":

    let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
    autonatClientStub.answer = NotReachable
    let autonatService = AutonatService.new(autonatClientStub, newRng(), maxQueueSize = 1)

    let relayClient = RelayClient.new()
    let privatePeerRelayAddr = newFuture[seq[MultiAddress]]()

    let publicPeerSwitch = createSwitch(RelayClient.new())
    proc checkMA(address: seq[MultiAddress]) =
      if not privatePeerRelayAddr.completed():
        echo $address
        privatePeerRelayAddr.complete(address)

    let autoRelayService = AutoRelayService.new(1, relayClient, checkMA, newRng())

    let hpservice = HPService.new(autonatService, autoRelayService, isPublicAddrIPAddrMock)

    let privatePeerSwitch = createSwitch(relayClient, hpservice)
    let switchRelay = createSwitch(Relay.new())

    await allFutures(switchRelay.start(), privatePeerSwitch.start(), publicPeerSwitch.start())

    await privatePeerSwitch.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)

    await publicPeerSwitch.connect(privatePeerSwitch.peerInfo.peerId, (await privatePeerRelayAddr))

    checkExpiring:
      privatePeerSwitch.connManager.connCount(publicPeerSwitch.peerInfo.peerId) == 1 and
      not isRelayed(privatePeerSwitch.connManager.selectMuxer(publicPeerSwitch.peerInfo.peerId).connection)

    for t in privatePeerSwitch.transports:
      echo t.networkReachability

    await allFuturesThrowing(
      privatePeerSwitch.stop(), publicPeerSwitch.stop(), switchRelay.stop())

  # asyncTest "Hope Punching Public Reachability test":
  #   let switch1 = createSwitch()
  #
  #   let switch2 = createSwitch()
  #   let switch3 = createSwitch()
  #   let switch4 = createSwitch()
  #
  #   let autonatService = AutonatService.new(AutonatClient.new(), newRng())
  #
  #   let relayClient = RelayClient.new()
  #   let fut = newFuture[void]()
  #   proc checkMA(address: seq[MultiAddress]) =
  #     check: address[0] == buildRelayMA(switchRelay, switchClient)
  #     fut.complete()
  #   let autoRelayService = AutoRelayService.new(3, relayClient, checkMA, newRng())
  #
  #   let hpservice = HPService.new(autonatService, autoRelayService, newRng())
  #
  #   switch1.addService(hpservice)
  #
  #   # proc f(ma: MultiAddress) {.gcsafe, async.} =
  #   #   echo "onNewRelayAddr shouldn't be called"
  #   #   fail()
  #   #
  #   # hpservice.onNewRelayAddr(f)
  #
  #   await switch1.start()
  #   await switch2.start()
  #   await switch3.start()
  #   await switch4.start()
  #
  #   await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
  #   await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
  #   await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)
  #
  #   await autonatStub.finished
  #
  #   await allFuturesThrowing(
  #     switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())
  #
  # asyncTest "Hope Punching Full Reachability test":
  #
  #   let rdv1 = RendezVous.new()
  #   let rdv2 = RendezVous.new()
  #
  #   let relayClient = RelayClient.new()
  #   let switch1 = createSwitch(rdv1, relayClient)
  #   let switch2 = createSwitch(rdv2)
  #   let switch3 = createSwitch()
  #   let switch4 = createSwitch()
  #
  #   let bootRdv = RendezVous.new()
  #   let bootNode = createSwitch(rdv = bootRdv)
  #   await bootNode.start()
  #
  #   let relay = Relay.new()
  #   let relayRdv = RendezVous.new()
  #   let relaySwitch = createSwitch(rdv = relayRdv, relay = relay)
  #   await relaySwitch.start()
  #
  #   await relaySwitch.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
  #
  #   let dm = DiscoveryManager()
  #   dm.add(RendezVousInterface.new(relayRdv))
  #   dm.advertise(RdvNamespace("relay"))
  #
  #   let autonatStub = AutonatStub.new(expectedDials = 8)
  #   autonatStub.returnSuccess = false
  #
  #   let autonatService = AutonatService.new(autonatStub, newRng(), some(1.seconds))
  #   let hpservice = HPService.new(rdv1, relayClient, autonatService)
  #
  #   switch1.addService(hpservice)
  #   await switch1.start()
  #
  #   let awaiter = Awaiter.new()
  #
  #   proc f(ma: MultiAddress) {.gcsafe, async.} =
  #     autonatStub.returnSuccess = true
  #     let expected = MultiAddress.init($relaySwitch.peerInfo.addrs[0] & "/p2p/" &
  #                           $relaySwitch.peerInfo.peerId & "/p2p-circuit/p2p/" &
  #                           $switch1.peerInfo.peerId).get()
  #     check ma == expected
  #     awaiter.finished.complete()
  #
  #   hpservice.onNewRelayAddr(f)
  #
  #   await switch2.start()
  #   await switch3.start()
  #   await switch4.start()
  #
  #   await switch1.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
  #
  #   await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
  #   await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
  #   await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)
  #
  #   await awaiter.finished
  #
  #   await hpservice.run(switch1)
  #
  #   await autonatStub.finished
  #
  #   await allFuturesThrowing(
  #     bootNode.stop(), relaySwitch.stop(), switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())