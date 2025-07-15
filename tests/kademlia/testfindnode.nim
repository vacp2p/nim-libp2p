{.used.}
import chronicles, strformat, sequtils
import std/enumerate
import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../../libp2p/protocols/kademlia/routingtable
import ../../libp2p/protocols/kademlia/keys
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

proc countBucketEntries(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

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
    await switches.mapIt(it.start()).allFutures()

    # Now we can activate the network
    # Needs to be done sequentially, hence the deterministic ordering of completion
    for i in 1 ..< swarmSize:
      await kads[i].bootstrap(@[switches[0].peerInfo])

    # TODO: see how other impls do their tests.
    # Similarly, refer to the mathematical properties according to the spec, and systematically cover all possible states.
    var entries = @[kads[0].rtable.selfId]

    # assert all the nodes that bootstropped off kad[0] has exactly 1 of each previous nodes, + kads[0], in their buckets
    for i, kad in enumerate(kads[1 ..^ 1]):
      for id in entries:
        let count = countBucketEntries(kad.rtable.buckets, id)
        doAssert(
          count == 1,
          fmt"bootstrap state broken - count: {count}|entries: {entries}|i: {i}|key: {id}|buckets: {kad.rtable.buckets}",
        )
      entries.add(kad.rtable.selfId)

    trace "Simple findNode precondition asserted"

    discard await kads[1].findNode(kads[2].rtable.selfId)

    # assert that every node has exactly one entry for the id of every other node
    for id in entries:
      for k in kads:
        if k.rtable.selfId == id:
          continue
        let count = countBucketEntries(k.rtable.buckets, id)
        doAssert(
          count == 1,
          fmt"findNode post-check broken - entries: {entries}|id: {id}|buckets: {k.rtable.buckets}",
        )

  asyncTest "Relay find peer":
    let parentSwitch = createSwitch()
    let parentKad = KadDHT.new(parentSwitch)
    parentSwitch.mount(parentKad)
    await parentSwitch.start()

    let broSwitch = createSwitch()
    let broKad = KadDHT.new(broSwitch)
    broSwitch.mount(broKad)
    await broSwitch.start()

    let sisSwitch = createSwitch()
    let sisKad = KadDHT.new(sisSwitch)
    sisSwitch.mount(sisKad)
    await sisSwitch.start()

    let neiceSwitch = createSwitch()
    let neiceKad = KadDHT.new(neiceSwitch)
    neiceSwitch.mount(neiceKad)
    await neiceSwitch.start()

    await broKad.bootstrap(@[parentSwitch.peerInfo])
    # TODO: assert parent only has broKad and visa versa
    await sisKad.bootstrap(@[parentSwitch.peerInfo])
    # TODO: assert same again, but sisKad has parent and br, and sis has been added to parent
    await neiceKad.bootstrap(@[sisSwitch.peerInfo])
    # TODO: assert same again, but sisKad has neice added, and neice has the same content as sis

    # Bro should only know parent
    doAssert(countBucketEntries(broKad.rtable.buckets, parentKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(broKad.rtable.buckets, sisKad.rtable.selfId) == 0)
    doAssert(countBucketEntries(broKad.rtable.buckets, neiceKad.rtable.selfId) == 0)

    discard await broKad.findNode(neiceKad.rtable.selfId)

    # Bro should now know of sis and neice as well
    doAssert(countBucketEntries(broKad.rtable.buckets, parentKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(broKad.rtable.buckets, sisKad.rtable.selfId) == 1)
    doAssert(
      countBucketEntries(broKad.rtable.buckets, neiceKad.rtable.selfId) == 1,
      fmt"brobuck: {broKad.rtable.buckets}|neice: {neiceKad.rtable.selfId}",
    )
