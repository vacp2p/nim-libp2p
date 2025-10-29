{.used.}
from std/times import now, utc
import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../utils/unittests
import ./utils.nim
import ../helpers

suite "KadDHT - AddProvider":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch3, kad3) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    await kad1.bootstrap(@[switch2.peerInfo])
    await kad3.bootstrap(@[switch2.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad3.findNode(kad2.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)
    kad2.dataTable.insert(key, value, $times.now().utc)
    kad3.dataTable.insert(key, value, $times.now().utc)

    # repeat several times because address book can be updated by multiple sources

    # ensure kad1 does not have kad3 in its addressbook
    discard switch1.peerStore[AddressBook].del(switch3.peerInfo.peerId)
    check switch1.peerStore[AddressBook][switch3.peerInfo.peerId] !=
      switch3.peerInfo.addrs

    # kad1 has kad3 in its addressbook after adding provider
    await kad3.addProvider(key.toCid())
    await sleepAsync(10.milliseconds)
    check switch1.peerStore[AddressBook][switch3.peerInfo.peerId] ==
      switch3.peerInfo.addrs

    # now repeat the above without calling addProvider, should fail
    # ensure kad1 does not have kad3 in its addressbook
    discard switch1.peerStore[AddressBook].del(switch3.peerInfo.peerId)
    check switch1.peerStore[AddressBook][switch3.peerInfo.peerId] !=
      switch3.peerInfo.addrs

    await sleepAsync(10.milliseconds)
    check switch1.peerStore[AddressBook][switch3.peerInfo.peerId] !=
      switch3.peerInfo.addrs
