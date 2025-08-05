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

method validate(self: PermissiveValidator, cand: EntryCandidate): bool =
  info "validating true"
  true

type RestrictiveValidator = ref object of EntryValidator

type ApatheticSelector = ref object of EntrySelector
method select(
    self: ApatheticSelector, cand: RecordVal, others: seq[RecordVal]
): RecordVal =
  return cand

method validate(self: RestrictiveValidator, cand: EntryCandidate): bool =
  info "validating false"
  false

suite "KadDHT - PutVal":
  asyncTest "Simple put":
    let swarmSize = 3
    var switches: seq[Switch]
    var kads: seq[KadDHT]
    # every node needs a switch, and an assosciated kad mounted to it
    for i in 0 ..< swarmSize:
      switches.add(createSwitch())
      kads.add(KadDHT.new(switches[i], PermissiveValidator(), ApatheticSelector()))
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
    let entryVal = EntryVal(data: puttedData)
    let hashedData: seq[byte] = @(sha256.digest(puttedData).data)
    discard await kads[0].putVal(hashedData.toKey(), entryVal, 2)

    let entered1: EntryVal = kads[0].dataTable.entries[EntryKey(data: hashedData)].val
    let entered2: EntryVal = kads[1].dataTable.entries[EntryKey(data: hashedData)].val

    var ents = kads[0].dataTable.entries
    doAssert(
      entered1.data == puttedData,
      fmt"table: {ents}, putted: {puttedData}, expected-hash: {hashedData}",
    )
    doAssert(len(kads[0].dataTable.entries) == 1)

    ents = kads[1].dataTable.entries
    doAssert(
      entered2.data == puttedData,
      fmt"table: {ents}, putted: {puttedData}, expected-hash: {hashedData}",
    )
    doAssert(len(kads[1].dataTable.entries) == 1)

  asyncTest "Change Validator":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, RestrictiveValidator(), ApatheticSelector())
    var kad2 = KadDHT.new(switch2, RestrictiveValidator(), ApatheticSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)

    await allFutures(switch1.start(), switch2.start())

    await kad2.bootstrap(@[switch1.peerInfo])
    doAssert(len(kad1.dataTable.entries) == 0)
    let puttedData = kad1.rtable.selfId.getBytes()
    let entryVal = EntryVal(data: puttedData)
    let hashedData: seq[byte] = @(sha256.digest(puttedData).data)
    discard await kad2.putVal(hashedData.toKey(), entryVal, 1)
    doAssert(len(kad1.dataTable.entries) == 0, fmt"content: {kad1.dataTable.entries}")
    kad1.entryValidator = PermissiveValidator()
    discard await kad2.putVal(hashedData.toKey(), entryVal, 1)

    doAssert(len(kad1.dataTable.entries) == 0, fmt"{kad1.dataTable.entries}")
    kad2.entryValidator = PermissiveValidator()
    discard await kad2.putVal(hashedData.toKey(), entryVal, 1)
    doAssert(len(kad1.dataTable.entries) == 1, fmt"{kad1.dataTable.entries}")

    await allFutures(kad1.stop(), kad2.stop())

  asyncTest "Good Time":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator(), ApatheticSelector())
    var kad2 = KadDHT.new(switch2, PermissiveValidator(), ApatheticSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)
    await allFutures(switch1.start(), switch2.start())
    await kad2.bootstrap(@[switch1.peerInfo])

    let puttedData = EntryVal(data: kad1.rtable.selfId.getBytes())
    let hashedData: seq[byte] = @(sha256.digest(puttedData.data).data)
    discard await kad2.putVal(hashedData.toKey(), puttedData, 1)

    let time: string = kad1.dataTable.entries[EntryKey(data: hashedData)].time.ts

    let now = times.now().utc
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)
    doAssert(elapsed < times.initDuration(seconds = 2))

    await allFutures(kad1.stop(), kad2.stop())
