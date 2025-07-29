{.used.}
import chronicles, strformat, sequtils
import std/enumerate
import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../../libp2p/protocols/kademlia/routingtable
import ../../libp2p/protocols/kademlia/keys
import ../../libp2p/protocols/kademlia/dhttypes
import unittest2
import ../utils/async_tests
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

type PermissiveValidator = ref object of EntryValidator

method validate(self: PermissiveValidator, key: EntryKey, val: EntryVal): bool =
  true
proc countBucketEntries(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

suite "KadDHT - FindNode":
  teardown:
    checkTrackers()
  asyncTest "Simple find peer":
    let swarmSize = 3
    var switches: seq[Switch]
    var kads: seq[KadDHT]
    # every node needs a switch, and an assosciated kad mounted to it
    for i in 0 ..< swarmSize:
      switches.add(createSwitch())
      kads.add(KadDHT.new(switches[i], PermissiveValidator()))
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
    await switches.mapIt(it.stop()).allFutures()

  asyncTest "Relay find peer":
    let parentSwitch = createSwitch()
    let parentKad = KadDHT.new(parentSwitch, PermissiveValidator())
    parentSwitch.mount(parentKad)
    await parentSwitch.start()

    let broSwitch = createSwitch()
    let broKad = KadDHT.new(broSwitch, PermissiveValidator())
    broSwitch.mount(broKad)
    await broSwitch.start()

    let sisSwitch = createSwitch()
    let sisKad = KadDHT.new(sisSwitch, PermissiveValidator())
    sisSwitch.mount(sisKad)
    await sisSwitch.start()

    let neiceSwitch = createSwitch()
    let neiceKad = KadDHT.new(neiceSwitch, PermissiveValidator())
    neiceSwitch.mount(neiceKad)
    await neiceSwitch.start()

    await broKad.bootstrap(@[parentSwitch.peerInfo])
    # Bro and parent know each other
    doAssert(countBucketEntries(broKad.rtable.buckets, parentKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(parentKad.rtable.buckets, broKad.rtable.selfId) == 1)

    await sisKad.bootstrap(@[parentSwitch.peerInfo])

    # Sis and parent know each other...
    doAssert(countBucketEntries(sisKad.rtable.buckets, parentKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(parentKad.rtable.buckets, sisKad.rtable.selfId) == 1)

    # But has been informed of bro by parent during bootstrap
    doAssert(countBucketEntries(sisKad.rtable.buckets, broKad.rtable.selfId) == 1)

    await neiceKad.bootstrap(@[sisSwitch.peerInfo])
    # Neice and sis know each other:
    doAssert(countBucketEntries(neiceKad.rtable.buckets, sisKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(sisKad.rtable.buckets, neiceKad.rtable.selfId) == 1)

    # But Neice has also been informed of those that Sis knows of:
    doAssert(countBucketEntries(neiceKad.rtable.buckets, parentKad.rtable.selfId) == 1)
    doAssert(countBucketEntries(neiceKad.rtable.buckets, broKad.rtable.selfId) == 1)

    # Now let's make sure that when Bro is trying to find neice, it's an "I know someone,
    # who knows someone, who knows the one I'm looking for"
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
    await parentSwitch.stop()
    await broSwitch.stop()
    await sisSwitch.stop()
    await neiceSwitch.stop()
