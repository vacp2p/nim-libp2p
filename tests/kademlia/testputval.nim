{.used.}
import std/[times, tables]
import chronicles
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/[kademlia, routingtable, keys]
import ../utils/async_tests
import ./utils.nim
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

proc countBucketEntries(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

proc containsData(kad: KadDHT, key: Key, value: seq[byte]): bool {.raises: [].} =
  try:
    kad.dataTable[key].value == value
  except KeyError:
    false

proc containsNoData(kad: KadDHT, key: Key): bool {.raises: [].} =
  not containsData(kad, key, @[])

template setupKadSwitch(validator: untyped, selector: untyped): untyped =
  let switch = createSwitch()
  let kad = KadDHT.new(switch, config = KadDHTConfig.new(validator, selector))
  switch.mount(kad)
  await switch.start()
  (switch, kad)

suite "KadDHT - PutVal":
  teardown:
    checkTrackers()
  asyncTest "Simple put":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    check:
      kad1.dataTable.len == 0
      kad2.dataTable.len == 0

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kad2.putValue(key, value, Opt.some(1))

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Change Validator":
    var (switch1, kad1) = setupKadSwitch(RestrictiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(RestrictiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])
    check kad1.dataTable.len == 0
    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    let putValRes1 = await kad2.putValue(key, value, Opt.some(1))
    check:
      (await kad2.putValue(key, value, Opt.some(1))).isErr()
      kad1.dataTable.len == 0

    kad1.config.validator = PermissiveValidator()
    let putValRes2 = await kad2.putValue(key, value, Opt.some(1))
    check:
      (await kad2.putValue(key, value, Opt.some(1))).isErr()
      kad1.dataTable.len == 0

    kad2.config.validator = PermissiveValidator()
    check:
      (await kad2.putValue(key, value, Opt.some(1))).isOk()
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Good Time":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kad2.putValue(key, value, Opt.some(1))

    let time: string = kad1.dataTable[key].time

    let now = times.now().utc
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)
    doAssert(elapsed < times.initDuration(seconds = 2))

  asyncTest "Reselect":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), OthersSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), OthersSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    discard await kad1.putValue(key, value, Opt.some(1))
    check:
      kad2.dataTable.len == 1
      kad2.dataTable[key].value == value

    let emptyVal: seq[byte] = @[]
    discard await kad1.putValue(key, emptyVal, Opt.some(1))
    check kad2.dataTable[key].value == value

    kad2.config.selector = CandSelector()
    kad1.config.selector = CandSelector()
    discard await kad1.putValue(key, emptyVal, Opt.some(1))
    check kad2.dataTable[key].value == emptyVal
