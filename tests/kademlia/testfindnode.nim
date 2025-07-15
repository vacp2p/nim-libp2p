{.used.}
import strformat
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
    # TODO: instead of awaiting sequentially, do it concurrently
    for i in 0 ..< swarmSize:
      await switches[i].start()

    # Now we can activate the network
    # TODO: instead of awaiting sequentially, do it concurrently
    for i in 1 ..< swarmSize:
      await kads[i].bootstrap(@[switches[0].peerInfo])

    # TODO: see how other impls do their tests.
    # Similarly, refer to the mathematical properties according to the spec, and systematically cover all possible states.
    var entries = @[kads[0].rtable.selfId]

    # assert all the nodes that bootstropped off kad[0] has exactly 1 of each previous nodes, + kads[0], in their buckets
    for i, kad in enumerate(kads[1 ..^ 1]):
      for id in entries:
        let count = countBucketEntries(kad.rtable.buckets, id)
        assert(
          count == 1,
          fmt"bootstrap state broken - count: {count}|entries: {entries}|i: {i}|key: {id}|buckets: {kad.rtable.buckets}",
        )
      entries.add(kad.rtable.selfId)

    echo "finding"
    discard await kads[1].findNode(kads[2].switch.peerInfo.peerId.toKey())

    echo "starting"
    # assert that every node has exactly one entry for the id of every other node
    for id in entries:
      for k in kads:
        if k.rtable.selfId == id:
          continue
        let count = countBucketEntries(k.rtable.buckets, id)
        assert(
          count == 1,
          fmt"findNode post-check broken - entries: {entries}|id: {id}|buckets: {k.rtable.buckets}",
        )
