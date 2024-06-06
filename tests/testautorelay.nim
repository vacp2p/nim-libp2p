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
import ../libp2p/[crypto/crypto,
                  protocols/connectivity/relay/relay,
                  protocols/connectivity/relay/client,
                  services/autorelayservice]
import ./helpers

proc createSwitch(r: Relay, autorelay: Service = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelay(r)
  if not autorelay.isNil():
    builder = builder.withServices(@[autorelay])
  builder.build()


proc buildRelayMA(switchRelay: Switch, switchClient: Switch): MultiAddress =
  MultiAddress.init($switchRelay.peerInfo.addrs[0] & "/p2p/" &
                    $switchRelay.peerInfo.peerId & "/p2p-circuit").get()

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
      check: addresses[0] == buildRelayMA(switchRelay, switchClient)
      check: addresses.len() == 1
      fut.complete()
    autorelay = AutoRelayService.new(3, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), switchRelay.start())
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await fut.wait(1.seconds)
    let addresses = autorelay.getAddresses()
    check:
      addresses[0] == buildRelayMA(switchRelay, switchClient)
      addresses.len() == 1
    await allFutures(switchClient.stop(), switchRelay.stop())

  asyncTest "Connect after starting switches":
    switchRelay = createSwitch(Relay.new())
    relayClient = RelayClient.new()
    let fut = newFuture[void]()
    proc checkMA(address: seq[MultiAddress]) =
      check: address[0] == buildRelayMA(switchRelay, switchClient)
      fut.complete()
    let autorelay = AutoRelayService.new(3, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), switchRelay.start())
    await sleepAsync(500.millis)
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await fut.wait(1.seconds)
    let addresses = autorelay.getAddresses()
    check:
      addresses == @[buildRelayMA(switchRelay, switchClient)]
      addresses.len() == 1
      addresses[0] in switchClient.peerInfo.addrs
    await allFutures(switchClient.stop(), switchRelay.stop())

    check addresses != switchClient.peerInfo.addrs

  asyncTest "Three relays connections":
    var state = 0
    let
      rel1 = createSwitch(Relay.new())
      rel2 = createSwitch(Relay.new())
      rel3 = createSwitch(Relay.new())
      fut = newFuture[void]()
    relayClient = RelayClient.new()
    proc checkMA(addresses: seq[MultiAddress]) =
      if state == 0 or state == 2:
        check:
          buildRelayMA(rel1, switchClient) in addresses
          addresses.len() == 1
        state += 1
      elif state == 1:
        check:
          buildRelayMA(rel1, switchClient) in addresses
          buildRelayMA(rel2, switchClient) in addresses
          addresses.len() == 2
        state += 1
      elif state == 3:
        check:
          buildRelayMA(rel1, switchClient) in addresses
          buildRelayMA(rel3, switchClient) in addresses
          addresses.len() == 2
        state += 1
        fut.complete()
    let autorelay = AutoRelayService.new(2, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await allFutures(switchClient.start(), rel1.start(), rel2.start(), rel3.start())
    await switchClient.connect(rel1.peerInfo.peerId, rel1.peerInfo.addrs)
    await sleepAsync(500.millis)
    await switchClient.connect(rel2.peerInfo.peerId, rel2.peerInfo.addrs)
    await switchClient.connect(rel3.peerInfo.peerId, rel3.peerInfo.addrs)
    await sleepAsync(500.millis)
    await rel2.stop()
    await fut.wait(1.seconds)
    let addresses = autorelay.getAddresses()
    check:
      buildRelayMA(rel1, switchClient) in addresses
      buildRelayMA(rel3, switchClient) in addresses
      addresses.len() == 2
    await allFutures(switchClient.stop(), rel1.stop(), rel3.stop())
