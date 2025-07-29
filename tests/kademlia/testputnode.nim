{.used.}
import chronicles
import strformat
import sequtils
import std/[times]
# import std/enumerate
import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../../libp2p/protocols/kademlia/routingtable
import ../../libp2p/protocols/kademlia/keys
import ../../libp2p/protocols/kademlia/dhttypes
import unittest2
import ../utils/async_tests
import std/tables

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

type PermissiveValidator = ref object of EntryValidator

method validate(self: PermissiveValidator, key: EntryKey, val: EntryVal): bool =
  true

type RestrictiveValidator = ref object of EntryValidator

method validate(self: RestrictiveValidator, key: EntryKey, val: EntryVal): bool =
  false

suite "KadDHT - PutNode":
  asyncTest "Simple put":
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

    discard await kads[1].findNode(kads[2].rtable.selfId)

    doAssert(len(kads[1].dataTable.entries) == 0)
    let puttedData = kads[1].rtable.selfId.getBytes()
    let hashedData: seq[byte] = @(sha256.digest(puttedData).data)
    discard await kads[0].putVal(puttedData, 1)

    let entered: EntryVal = kads[1].dataTable.entries[EntryKey(data: hashedData)][0]

    doAssert(
      entered.data == puttedData,
      fmt"table: {kads[1].dataTable.entries}, putted: {puttedData}, expected-hash: {hashedData}",
    )
    doAssert(len(kads[1].dataTable.entries) == 1)

  asyncTest "Change Validator":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, RestrictiveValidator())
    let kad2 = KadDHT.new(switch2, RestrictiveValidator())
    switch1.mount(kad1)
    switch2.mount(kad2)

    await allFutures(switch1.start(), switch2.start())

    await kad2.bootstrap(@[switch1.peerInfo])
    doAssert(len(kad1.dataTable.entries) == 0)
    discard await kad2.putVal(kad1.rtable.selfId.getBytes(), 1)
    error "status", stat = kad1.dataTable.entries
    doAssert(len(kad1.dataTable.entries) == 0, fmt"content: {kad1.dataTable.entries}")
    kad1.entryValidator = PermissiveValidator()
    discard await kad2.putVal(kad1.rtable.selfId.getBytes(), 1)

    doAssert(len(kad1.dataTable.entries) == 1, fmt"{kad1.dataTable.entries}")

    await allFutures(kad1.stop(), kad2.stop())

  asyncTest "Good Time":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator())
    let kad2 = KadDHT.new(switch2, PermissiveValidator())
    switch1.mount(kad1)
    switch2.mount(kad2)
    await allFutures(switch1.start(), switch2.start())
    await kad2.bootstrap(@[switch1.peerInfo])

    let puttedData = kad1.rtable.selfId.getBytes()
    let hashedData: seq[byte] = @(sha256.digest(puttedData).data)
    discard await kad2.putVal(puttedData, 1)

    info "putted", putted = puttedData
    info "sha256'd", shad = hashedData
    info "table", tab = kad1.dataTable.entries

    # the value in the table. created with `times.now().utc` then stringified
    let time: string = kad1.dataTable.entries[EntryKey(data: hashedData)][1].ts
    info "time", time = time

    # get "my now" the same way...
    let now = times.now().utc
    let nowstr = $now
    info "time now", now = nowstr
    # parse the stored time
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())
    let parsedstr = $parsed
    info "parsed", parsed = parsedstr
    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)

    doAssert(elapsed < times.initDuration(seconds = 2))

    await allFutures(kad1.stop(), kad2.stop())
