{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, options
import ../libp2p
import
  ../libp2p/[
    crypto/crypto,
    protocols/connectivity/relay/relay,
    protocols/connectivity/relay/client,
    services/autorelayservice,
  ]
import ./helpers

proc createSwitch(r: Relay, autorelay: Service = nil): Switch =
  var builder = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelay(r)
  if not autorelay.isNil():
    builder = builder.withServices(@[autorelay])
  builder.build()

proc buildRelayMA(switchRelay: Switch, switchClient: Switch): seq[MultiAddress] =
  result = newSeq[MultiAddress]()
  for i in 0 ..< switchRelay.peerInfo.addrs.len():
    result.add(
      MultiAddress
      .init(
        $switchRelay.peerInfo.addrs[i] & "/p2p/" & $switchRelay.peerInfo.peerId &
          "/p2p-circuit"
      )
      .get()
    )

suite "Autorelay":
  asyncTeardown:
    checkTrackers()

  var
    switchRelay {.threadvar.}: Switch
    switchClient {.threadvar.}: Switch
    relayClient {.threadvar.}: RelayClient
    autorelay {.threadvar.}: AutoRelayService

  asyncTest "Simple test":
    switchRelay = createSwitch(Relay.new())
    relayClient = RelayClient.new()
    let fut = newFuture[void]()
    proc checkMA(addresses: seq[MultiAddress]) =
      check:
        addresses == buildRelayMA(switchRelay, switchClient)
      fut.complete()

    autorelay = AutoRelayService.new(3, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), switchRelay.start())
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await fut.wait(1.seconds)
    let addresses = autorelay.getAddresses()
    check:
      addresses == buildRelayMA(switchRelay, switchClient)
    await allFutures(switchClient.stop(), switchRelay.stop())

  asyncTest "Connect after starting switches":
    switchRelay = createSwitch(Relay.new())
    relayClient = RelayClient.new()
    let fut = newFuture[void]()
    proc checkMA(address: seq[MultiAddress]) =
      check:
        address == buildRelayMA(switchRelay, switchClient)
      fut.complete()

    let autorelay = AutoRelayService.new(3, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), switchRelay.start())
    await sleepAsync(500.millis)
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await fut.wait(1.seconds)
    let addresses = autorelay.getAddresses()

    check:
      addresses == buildRelayMA(switchRelay, switchClient)
    for address in addresses:
      check address in switchClient.peerInfo.addrs

    await allFutures(switchClient.stop(), switchRelay.stop())

  asyncTest "Three relays connections":
    type RelayReservationState = enum
      Relay1Reserved
      Relay1AndRelay2Reserved
        # Although switchClient is connected to rel3, rel3 isn't reserved due to the maximum number of relays set to 2.
      Relay2UnreservedAndRelay1Reserved
      Relay1AndRelay3Reserved

    var state = Relay1Reserved
    let
      rel1 = createSwitch(Relay.new())
      rel2 = createSwitch(Relay.new())
      rel3 = createSwitch(Relay.new())
      rel1Checked = newFuture[void]()
      rel1And2Checked = newFuture[void]()
      allChecksCompleted = newFuture[void]()
    relayClient = RelayClient.new()
    proc checkMA(addresses: seq[MultiAddress]) =
      if state == Relay1Reserved or state == Relay2UnreservedAndRelay1Reserved:
        let relayMAs = buildRelayMA(rel1, switchClient)
        for relayMA in relayMAs:
          check:
            relayMA in addresses
        if state == Relay1Reserved:
          state = Relay1AndRelay2Reserved
          rel1Checked.complete()
        elif state == Relay2UnreservedAndRelay1Reserved:
          state = Relay1AndRelay3Reserved
      elif state == Relay1AndRelay2Reserved:
        let relay1MAs = buildRelayMA(rel1, switchClient)
        for relayMA in relay1MAs:
          check:
            relayMA in addresses
        let relay2MAs = buildRelayMA(rel2, switchClient)
        for relayMA in relay2MAs:
          check:
            relayMA in addresses
        state = Relay2UnreservedAndRelay1Reserved
        rel1And2Checked.complete()
      elif state == Relay1AndRelay3Reserved:
        let relay1MAs = buildRelayMA(rel1, switchClient)
        for relayMA in relay1MAs:
          check:
            relayMA in addresses
        let relay3MAs = buildRelayMA(rel3, switchClient)
        for relayMA in relay3MAs:
          check:
            relayMA in addresses
        allChecksCompleted.complete()

    let autorelay =
      AutoRelayService.new(maxNumRelays = 2, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), rel1.start(), rel2.start(), rel3.start())
    await switchClient.connect(rel1.peerInfo.peerId, rel1.peerInfo.addrs)
    await rel1Checked.wait(500.millis)
    await switchClient.connect(rel2.peerInfo.peerId, rel2.peerInfo.addrs)
    await switchClient.connect(rel3.peerInfo.peerId, rel3.peerInfo.addrs)
    await rel1And2Checked.wait(500.millis)
    await rel2.stop()
    await allChecksCompleted.wait(1.seconds)
    await allFutures(switchClient.stop(), rel1.stop(), rel3.stop())
