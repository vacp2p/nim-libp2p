{.used.}
import unittest2
import chronos
import chronicles
import std/[sequtils, enumerate]
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/[kademlia, routingtable, keys]
import ../helpers
import ../utils/async_tests
import ./utils.nim

proc createSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

proc hasKey(kad: KadDHT, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

suite "KadDHT - FindNode":
  teardown:
    checkTrackers()

  asyncTest "Simple find node":
    let swarmSize = 3
    var switches: seq[Switch]
    var kads: seq[KadDHT]
    # every node needs a switch, and an assosciated kad mounted to it
    for i in 0 ..< swarmSize:
      switches.add(createSwitch())
      kads.add(KadDHT.new(switches[i], PermissiveValidator(), CandSelector()))
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

    #  All the nodes that bootstropped off kad[0] has exactly 1 of each previous nodes, + kads[0], in their buckets
    for i, kad in enumerate(kads[1 ..^ 1]):
      for id in entries:
        check kad.hasKey(id)
      entries.add(kad.rtable.selfId)

    trace "Simple findNode precondition asserted"

    discard await kads[1].findNode(kads[2].rtable.selfId)

    # assert that every node has exactly one entry for the id of every other node
    for id in entries:
      for k in kads:
        if k.rtable.selfId == id:
          continue
        check k.hasKey(id)
    await switches.mapIt(it.stop()).allFutures()

  asyncTest "Relay find node":
    let parentSwitch = createSwitch()
    let parentKad = KadDHT.new(parentSwitch, PermissiveValidator(), CandSelector())
    parentSwitch.mount(parentKad)
    await parentSwitch.start()

    let broSwitch = createSwitch()
    let broKad = KadDHT.new(broSwitch, PermissiveValidator(), CandSelector())
    broSwitch.mount(broKad)
    await broSwitch.start()

    let sisSwitch = createSwitch()
    let sisKad = KadDHT.new(sisSwitch, PermissiveValidator(), CandSelector())
    sisSwitch.mount(sisKad)
    await sisSwitch.start()

    let neiceSwitch = createSwitch()
    let neiceKad = KadDHT.new(neiceSwitch, PermissiveValidator(), CandSelector())
    neiceSwitch.mount(neiceKad)
    await neiceSwitch.start()

    await broKad.bootstrap(@[parentSwitch.peerInfo])
    # Bro and parent know each other
    check:
      broKad.hasKey(parentKad.rtable.selfId)
      parentKad.hasKey(broKad.rtable.selfId)

    await sisKad.bootstrap(@[parentSwitch.peerInfo])

    # Sis and parent know each other...
    check:
      sisKad.hasKey(parentKad.rtable.selfId)
      parentKad.hasKey(sisKad.rtable.selfId)

    # But has been informed of bro by parent during bootstrap
    check sisKad.hasKey(broKad.rtable.selfId)

    await neiceKad.bootstrap(@[sisSwitch.peerInfo])
    # Neice and sis know each other:
    check:
      neiceKad.hasKey(sisKad.rtable.selfId)
      sisKad.hasKey(neiceKad.rtable.selfId)

    # But Neice has also been informed of those that Sis knows of:
    check:
      neiceKad.hasKey(parentKad.rtable.selfId)
      neiceKad.hasKey(broKad.rtable.selfId)

    # Now let's make sure that when Bro is trying to find neice, it's an "I know someone,
    # who knows someone, who knows the one I'm looking for, so forcing the routing table 
    # to look like this scenario
    for b in broKad.rtable.buckets.mitems:
      for p in b.peers:
        echo p.nodeId
      b.peers = b.peers.filterIt(
        it.nodeId != sisKad.rtable.selfId and it.nodeId != neiceKad.rtable.selfId
      )

    for b in broKad.rtable.buckets.mitems:
      echo b.peers.len

    check:
      broKad.hasKey(parentKad.rtable.selfId)
      not broKad.hasKey(sisKad.rtable.selfId)
      not broKad.hasKey(neiceKad.rtable.selfId)

    discard await broKad.findNode(neiceKad.rtable.selfId)

    # Bro should now know of sis and neice as well
    check:
      broKad.hasKey(parentKad.rtable.selfId)
      broKad.hasKey(sisKad.rtable.selfId)
      broKad.hasKey(neiceKad.rtable.selfId)

    await parentSwitch.stop()
    await broSwitch.stop()
    await sisSwitch.stop()
    await neiceSwitch.stop()

  asyncTest "Find peer":
    let aliceSwitch = createSwitch()
    let aliceKad = KadDHT.new(aliceSwitch, PermissiveValidator(), CandSelector())
    aliceSwitch.mount(aliceKad)
    await aliceSwitch.start()

    let bobSwitch = createSwitch()
    let bobKad = KadDHT.new(bobSwitch, PermissiveValidator(), CandSelector())
    bobSwitch.mount(bobKad)
    await bobSwitch.start()

    let charlieSwitch = createSwitch()
    let charlieKad = KadDHT.new(charlieSwitch, PermissiveValidator(), CandSelector())
    charlieSwitch.mount(charlieKad)
    await charlieSwitch.start()

    await bobKad.bootstrap(@[aliceSwitch.peerInfo])
    await charlieKad.bootstrap(@[aliceSwitch.peerInfo])

    let peerInfoRes = await bobKad.findPeer(charlieSwitch.peerInfo.peerId)
    check:
      peerInfoRes.isOk
      peerInfoRes.get().peerId == charlieSwitch.peerInfo.peerId

    let peerInfoRes2 = await bobKad.findPeer(PeerId.random(newRng()).get())
    check peerInfoRes2.isErr

    await aliceSwitch.stop()
    await bobSwitch.stop()
    await charlieSwitch.stop()
