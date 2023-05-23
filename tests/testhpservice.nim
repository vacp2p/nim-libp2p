# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos

import unittest2
import ./helpers
import ./stubs/switchstub
import ../libp2p/[builders,
                  switch,
                  services/hpservice,
                  services/autorelayservice]
import ../libp2p/protocols/connectivity/relay/[relay, client]
import ../libp2p/protocols/connectivity/autonat/[service]
import ../libp2p/nameresolving/nameresolver
import ../libp2p/nameresolving/mockresolver

import stubs/autonatclientstub

proc isPublicAddrIPAddrMock(ta: TransportAddress): bool =
  return true

proc createSwitch(r: Relay = nil, hpService: Service = nil, nameResolver: NameResolver = nil): Switch {.raises: [LPError, Defect].} =
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

  if nameResolver != nil:
    builder = builder.withNameResolver(nameResolver)

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
        privatePeerRelayAddr.complete(address)

    let autoRelayService = AutoRelayService.new(1, relayClient, checkMA, newRng())

    let hpservice = HPService.new(autonatService, autoRelayService, isPublicAddrIPAddrMock)

    let privatePeerSwitch = createSwitch(relayClient, hpservice)
    let peerSwitch = createSwitch()
    let switchRelay = createSwitch(Relay.new())

    await allFutures(switchRelay.start(), privatePeerSwitch.start(), publicPeerSwitch.start(), peerSwitch.start())

    await privatePeerSwitch.connect(peerSwitch.peerInfo.peerId, peerSwitch.peerInfo.addrs) # for autonat
    checkExpiring:
      autoRelayService.running # wait for autorelay to kick in
    await privatePeerSwitch.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)

    await publicPeerSwitch.connect(privatePeerSwitch.peerInfo.peerId, (await privatePeerRelayAddr))

    checkExpiring:
      privatePeerSwitch.connManager.connCount(publicPeerSwitch.peerInfo.peerId) == 1 and
      not isRelayed(privatePeerSwitch.connManager.selectMuxer(publicPeerSwitch.peerInfo.peerId).connection)

    await allFuturesThrowing(
      privatePeerSwitch.stop(), publicPeerSwitch.stop(), switchRelay.stop(), peerSwitch.stop())

  asyncTest "Direct connection must work when peer address is public and dns is used":

    let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
    autonatClientStub.answer = NotReachable
    let autonatService = AutonatService.new(autonatClientStub, newRng(), maxQueueSize = 1)

    let relayClient = RelayClient.new()
    let privatePeerRelayAddr = newFuture[seq[MultiAddress]]()

    let resolver = MockResolver.new()
    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
    resolver.ipResponses[("localhost", true)] = @["::1"]

    let publicPeerSwitch = createSwitch(RelayClient.new(), nameResolver = resolver)

    proc addressMapper(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.gcsafe, async.} =
        return @[MultiAddress.init("/dns4/localhost/").tryGet() & listenAddrs[0][1].tryGet()]
    publicPeerSwitch.peerInfo.addressMappers.add(addressMapper)
    await publicPeerSwitch.peerInfo.update()

    proc checkMA(address: seq[MultiAddress]) =
      if not privatePeerRelayAddr.completed():
        privatePeerRelayAddr.complete(address)

    let autoRelayService = AutoRelayService.new(1, relayClient, checkMA, newRng())

    let hpservice = HPService.new(autonatService, autoRelayService, isPublicAddrIPAddrMock)

    let privatePeerSwitch = createSwitch(relayClient, hpservice, nameResolver = resolver)
    let peerSwitch = createSwitch()
    let switchRelay = createSwitch(Relay.new())

    await allFutures(switchRelay.start(), privatePeerSwitch.start(), publicPeerSwitch.start(), peerSwitch.start())

    await privatePeerSwitch.connect(peerSwitch.peerInfo.peerId, peerSwitch.peerInfo.addrs) # for autonat
    checkExpiring:
      autoRelayService.running # wait for autorelay to kick in
    await privatePeerSwitch.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)

    await publicPeerSwitch.connect(privatePeerSwitch.peerInfo.peerId, (await privatePeerRelayAddr))

    checkExpiring:
      privatePeerSwitch.connManager.connCount(publicPeerSwitch.peerInfo.peerId) == 1 and
      not isRelayed(privatePeerSwitch.connManager.selectMuxer(publicPeerSwitch.peerInfo.peerId).connection)

    await allFuturesThrowing(
      privatePeerSwitch.stop(), publicPeerSwitch.stop(), switchRelay.stop(), peerSwitch.stop())

  proc holePunchingTest(connectStub: proc (): Future[void] {.async.},
                        isPublicIPAddrProc: IsPublicIPAddrProc,
                        answer: Answer) {.async.} =
    # There's no check in this test cause it can't test hole punching locally. It exists just to be sure the rest of
    # the code works properly.

    let autonatClientStub1 = AutonatClientStub.new(expectedDials = 1)
    autonatClientStub1.answer = NotReachable
    let autonatService1 = AutonatService.new(autonatClientStub1, newRng(), maxQueueSize = 1)

    let autonatClientStub2 = AutonatClientStub.new(expectedDials = 1)
    autonatClientStub2.answer = answer
    let autonatService2 = AutonatService.new(autonatClientStub2, newRng(), maxQueueSize = 1)

    let relayClient1 = RelayClient.new()
    let relayClient2 = RelayClient.new()
    let privatePeerRelayAddr1 = newFuture[seq[MultiAddress]]()

    proc checkMA(address: seq[MultiAddress]) =
      if not privatePeerRelayAddr1.completed():
        privatePeerRelayAddr1.complete(address)

    let autoRelayService1 = AutoRelayService.new(1, relayClient1, checkMA, newRng())
    let autoRelayService2 = AutoRelayService.new(1, relayClient2, nil, newRng())

    let hpservice1 = HPService.new(autonatService1, autoRelayService1, isPublicIPAddrProc)
    let hpservice2 = HPService.new(autonatService2, autoRelayService2)

    let privatePeerSwitch1 = SwitchStub.new(createSwitch(relayClient1, hpservice1))
    let privatePeerSwitch2 = createSwitch(relayClient2, hpservice2)
    let switchRelay = createSwitch(Relay.new())
    let switchAux = createSwitch()
    let switchAux2 = createSwitch()
    let switchAux3 = createSwitch()
    let switchAux4 = createSwitch()

    var awaiter = newFuture[void]()

    await allFutures(
      switchRelay.start(), privatePeerSwitch1.start(), privatePeerSwitch2.start(),
      switchAux.start(), switchAux2.start(), switchAux3.start(), switchAux4.start()
    )

    await privatePeerSwitch1.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await privatePeerSwitch2.connect(switchAux.peerInfo.peerId, switchAux.peerInfo.addrs)

    await sleepAsync(200.millis)

    await privatePeerSwitch1.connect(switchAux2.peerInfo.peerId, switchAux2.peerInfo.addrs)
    await privatePeerSwitch1.connect(switchAux3.peerInfo.peerId, switchAux3.peerInfo.addrs)
    await privatePeerSwitch1.connect(switchAux4.peerInfo.peerId, switchAux4.peerInfo.addrs)

    await privatePeerSwitch2.connect(switchAux2.peerInfo.peerId, switchAux2.peerInfo.addrs)
    await privatePeerSwitch2.connect(switchAux3.peerInfo.peerId, switchAux3.peerInfo.addrs)
    await privatePeerSwitch2.connect(switchAux4.peerInfo.peerId, switchAux4.peerInfo.addrs)

    privatePeerSwitch1.connectStub = connectStub
    await privatePeerSwitch2.connect(privatePeerSwitch1.peerInfo.peerId, (await privatePeerRelayAddr1))

    await sleepAsync(200.millis)

    await allFuturesThrowing(
      privatePeerSwitch1.stop(), privatePeerSwitch2.stop(), switchRelay.stop(),
      switchAux.stop(), switchAux2.stop(), switchAux3.stop(), switchAux4.stop())

  asyncTest "Hole punching when peers addresses are private":
    await holePunchingTest(nil, isGlobal, NotReachable)

  asyncTest "Hole punching when there is an error during unilateral direct connection":

    proc connectStub(): Future[void] {.async.} =
      raise newException(CatchableError, "error")

    await holePunchingTest(connectStub, isPublicAddrIPAddrMock, Reachable)
