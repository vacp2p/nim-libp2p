{.used.}
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/kademlia
import ../utils/async_tests
import ./utils.nim
import ../helpers

proc createSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

suite "KadDHT - Ping":
  teardown:
    checkTrackers()

  asyncTest "Simple ping":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator(), CandSelector())
    var kad2 = KadDHT.new(switch2, PermissiveValidator(), CandSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)

    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    check:
      await kad1.ping(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
      await kad2.ping(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
