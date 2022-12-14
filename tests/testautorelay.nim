{.used.}

import bearssl, chronos, options
import ../libp2p
import ../libp2p/[protocols/connectivity/relay/relay,
                  protocols/connectivity/relay/messages,
                  protocols/connectivity/relay/utils,
                  protocols/connectivity/relay/client,
                  protocols/connectivity/autorelay]
import ./helpers
import std/times
import stew/byteutils

proc createSwitch(r: Relay): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelay(r)
    .build()

suite "Autorelay":
  asyncTeardown:
    checkTrackers()

  asyncTest "Simple test":
    let relay = createSwitch(Relay.new())
    let client = RelayClient.new()
    let switch = createSwitch(client)
    let fut = newFuture[void]()
    proc checkMA(address: MultiAddress) {.async.} =
      check: address == MultiAddress.init($relay.peerInfo.addrs[0] & "/p2p/" &
                                          $relay.peerInfo.peerId & "/p2p-circuit/p2p/" &
                                          $switch.peerInfo.peerId).get()
      fut.complete()
    let autorelay = AutoRelayService.new(3, client, checkMA)
    switch.addService(autorelay)
    await switch.start()
    await relay.start()
    await switch.connect(relay.peerInfo.peerId, relay.peerInfo.addrs)

    discard autorelay.run(switch)

    await fut
    await switch.stop()
    await relay.stop()
