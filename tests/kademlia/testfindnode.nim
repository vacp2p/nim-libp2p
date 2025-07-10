import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import unittest2
import ../utils/async_tests

proc createSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

suite "KadDHT - FindNode":
  asyncTest "Simple find peer":
    let
      s1 = createSwitch()
      s2 = createSwitch()
      s3 = createSwitch()
      kad1 = KadDHT.new(s1)
      kad2 = KadDHT.new(s2)
      kad3 = KadDHT.new(s3)

    s1.mount(kad1)
    s2.mount(kad2)
    s3.mount(kad3)

    await s1.start()
    await s2.start()
    await s3.start()

    await kad2.bootstrap(@[s1.peerInfo])
    await kad3.bootstrap(@[s1.peerInfo])

    await sleepAsync(2.seconds)

    # TODO: test



