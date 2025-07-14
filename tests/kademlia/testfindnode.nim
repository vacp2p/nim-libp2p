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
    let swarmSize = 3
    var switches: seq[Switch]
    var kads: seq[KadDHT]
    # every node needs a switch, and an assosciated kad mounted to it
    for i in 0 ..< swarmSize:
      switches.add(createSwitch())
      kads.add(KadDHT.new(switches[i]))
      switches[i].mount(kads[i])

    # Once the the creation/mounting of switches are done, we can start
    # TODO: instead of awaiting sequentially, do it concurrently
    for i in 0 ..< swarmSize:
      await switches[i].start()

    # Now we can activate the network
    # TODO: instead of awaiting sequentially, do it concurrently
    for i in 1 ..< swarmSize:
      await kads[i].bootstrap(@[switches[0].peerInfo])

    await sleepAsync(2.seconds)

    # TODO: test
