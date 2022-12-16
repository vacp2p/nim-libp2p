{.used.}

import chronos, options
import ../libp2p
import ../libp2p/[protocols/connectivity/relay/relay,
                  protocols/connectivity/relay/messages,
                  protocols/connectivity/relay/utils,
                  protocols/connectivity/relay/client,
                  protocols/connectivity/autorelay]
import ./helpers
import stew/byteutils

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
                    $switchRelay.peerInfo.peerId & "/p2p-circuit/p2p/" &
                    $switchClient.peerInfo.peerId).get()

let rng = newRng()
suite "Autorelay":
  asyncTeardown:
    checkTrackers()

  var
    rng {.threadvar.}: ref HmacDrbgContext
    switchRelay {.threadvar.}: Switch
    switchClient {.threadvar.}: Switch
    relayClient {.threadvar.}: RelayClient
    autorelay {.threadvar.}: AutoRelayService

  asyncSetup:
    rng = newRng()

  asyncTest "Simple test":
    switchRelay = createSwitch(Relay.new())
    relayClient = RelayClient.new()
    let fut = newFuture[void]()
    proc checkMA(addresses: seq[MultiAddress]) =
      check: addresses[0] == buildRelayMA(switchRelay, switchClient)
      check: addresses.len() == 1
      fut.complete()
    autorelay = AutoRelayService.new(3, relayClient, checkMA, rng)
    switchClient = createSwitch(relayClient, autorelay)
    await switchClient.start()
    await switchRelay.start()
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    discard autorelay.run(switchClient)
    await fut
    echo "ahbahouais"
    let addresses = autorelay.getAddresses()
    check: addresses[0] == buildRelayMA(switchRelay, switchClient)
    check: addresses.len() == 1
    await switchClient.stop()
    await switchRelay.stop()

  asyncTest "Connect after starting switches":
    switchRelay = createSwitch(Relay.new())
    relayClient = RelayClient.new()
    let fut = newFuture[void]()
    proc checkMA(address: seq[MultiAddress]) =
      check: address[0] == buildRelayMA(switchRelay, switchClient)
      fut.complete()
    let autorelay = AutoRelayService.new(3, relayClient, checkMA, newRng())
    switchClient = createSwitch(relayClient, autorelay)
    await switchClient.start()
    await switchRelay.start()
    discard autorelay.run(switchClient)
    await sleepAsync(500.millis)
    await switchClient.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await fut.wait(1.seconds)
    await switchClient.stop()
    await switchRelay.stop()
