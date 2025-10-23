{.used.}
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../utils/async_tests
import ./utils.nim
import ../helpers

suite "KadDHT - Ping":
  teardown:
    checkTrackers()

  asyncTest "Simple ping":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())

    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    check:
      await kad1.ping(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
      await kad2.ping(switch1.peerInfo.peerId, switch1.peerInfo.addrs)
