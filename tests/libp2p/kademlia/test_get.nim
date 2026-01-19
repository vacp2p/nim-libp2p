# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

from std/times import now, utc
import chronos
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./[mock_kademlia, utils]

suite "KadDHT Get":
  teardown:
    checkTrackers()

  asyncTest "Get from peer":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kads[0].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[0].containsData(key, value)
      kads[1].containsNoData(key)

    let record = await kads[1].getValue(key, quorumOverride = Opt.some(1))

    check:
      record.get().value == value
      kads[0].containsData(key, value)
      kads[1].containsData(key, value)

  asyncTest "Get value that is locally present":
    let kads = await setupKadSwitches(1)
    defer:
      await stopNodes(kads)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kads[0].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[0].containsData(key, value)
      (await kads[0].getValue(key, quorumOverride = Opt.some(1))).get().value == value

  asyncTest "Divergent getVal responses from peers":
    let kads =
      await setupKadSwitches(5, DefaultEntryValidator(), DefaultEntrySelector())
    defer:
      await stopNodes(kads)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      bestValue = @[1.byte, 2, 3, 4, 5]
      worstValue = @[1.byte, 2, 3, 4, 6]

    kads[1].dataTable.insert(key, bestValue, $times.now().utc)
    kads[2].dataTable.insert(key, worstValue, $times.now().utc)
    kads[3].dataTable.insert(key, bestValue, $times.now().utc)
    kads[4].dataTable.insert(key, bestValue, $times.now().utc)

    check:
      kads[0].containsNoData(key)
      kads[1].containsData(key, bestValue)
      kads[2].containsData(key, worstValue)
      kads[3].containsData(key, bestValue)
      kads[4].containsData(key, bestValue)

    let record = await kads[0].getValue(key, quorumOverride = Opt.some(3))

    # now all have bestvalue
    check:
      record.get().value == bestValue
      kads[0].containsData(key, bestValue)
      kads[1].containsData(key, bestValue)
      kads[2].containsData(key, bestValue)
      kads[3].containsData(key, bestValue)
      kads[4].containsData(key, bestValue)

  asyncTest "Could not achieve quorum":
    let kads =
      await setupKadSwitches(5, DefaultEntryValidator(), DefaultEntrySelector())
    defer:
      await stopNodes(kads)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kads[1].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[0].containsNoData(key)
      kads[1].containsData(key, value)
      kads[2].containsNoData(key)
      kads[3].containsNoData(key)
      kads[4].containsNoData(key)

    let record = await kads[0].getValue(key)
    check record.isErr()
    check record.error() == "Not enough valid records to achieve quorum, needed 5 got 1"

  asyncTest "Update peers with empty values":
    let kads =
      await setupKadSwitches(5, DefaultEntryValidator(), DefaultEntrySelector())
    defer:
      await stopNodes(kads)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kads[1].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[0].containsNoData(key)
      kads[1].containsData(key, value)
      kads[2].containsNoData(key)
      kads[3].containsNoData(key)
      kads[4].containsNoData(key)

    # 1 is enough to make a decision
    let record = await kads[0].getValue(key, quorumOverride = Opt.some(1))

    # peers are updated
    check:
      record.get().value == value
      kads[0].containsData(key, value)
      kads[1].containsData(key, value)
      kads[2].containsData(key, value)
      kads[3].containsData(key, value)
      kads[4].containsData(key, value)

  asyncTest "Get updates routing table with closerPeers (no record)":
    # kads[2] <---> kads[0] (hub) <---> kads[1]
    let kads = await setupKadSwitches(
      3,
      PermissiveValidator(),
      CandSelector(),
      @[],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    let key = kads[0].rtable.selfId

    check:
      kads[2].hasKey(kads[0].rtable.selfId)
      not kads[2].hasKey(kads[1].rtable.selfId)

    # When kads[0] doesn't have the value, handleGetValue returns only closerPeers
    let record = await kads[2].getValue(key, quorumOverride = Opt.some(1))

    # kads[2] should discover kads[1] through the closerPeers in the response
    check:
      record.isErr()
      kads[2].hasKey(kads[1].rtable.selfId) # discovered via closerPeers

  asyncTest "Get updates routing table with closerPeers (with record)":
    # kads[2] <---> kads[0] (hub) <---> kads[1]
    let kads = await setupKadSwitches(
      3,
      PermissiveValidator(),
      CandSelector(),
      @[],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kads[0].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[2].hasKey(kads[0].rtable.selfId)
      not kads[2].hasKey(kads[1].rtable.selfId)

    # When kads[0] has the value, handleGetValue returns both record and closerPeers
    let record = await kads[2].getValue(key, quorumOverride = Opt.some(1))

    # kads[2] should discover kads[1] through the closerPeers in the response.
    check:
      record.get().value == value
      kads[2].hasKey(kads[1].rtable.selfId) # discovered via closerPeers

  asyncTest "Quorum handling is ignored if quorum is 0 or 1":
    let kads = await setupKadSwitches(
      3,
      PermissiveValidator(),
      CandSelector(),
      @[],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    defer:
      await stopNodes(kads)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      valueLocal = @[1.byte, 1, 1, 1, 1]
      valueRemote = @[2.byte, 2, 2, 2, 2]

    # kad2 and kad3 have different values than kad1
    kads[0].dataTable.insert(key, valueLocal, $times.now().utc)
    kads[1].dataTable.insert(key, valueRemote, $times.now().utc)
    kads[2].dataTable.insert(key, valueRemote, $times.now().utc)

    # but when quorum is 0 or 1 we ignore remote values and use local value

    check:
      (await kads[0].getValue(key, quorumOverride = Opt.some(0))).get().value ==
        valueLocal
      (await kads[0].getValue(key, quorumOverride = Opt.some(1))).get().value ==
        valueLocal

  asyncTest "GET_VALUE rejects record where Record.key does not match requested key":
    let
      (victimSwitch, victim) =
        await setupKadSwitch(PermissiveValidator(), CandSelector())
      (maliciousSwitch, malicious) = await setupMockKadSwitch(
        PermissiveValidator(), CandSelector(), getValueResponse = MismatchedKey
      )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victim, malicious)

    let requestedKey = victim.rtable.selfId
    check victim.containsNoData(requestedKey)

    # When victim calls getValue, malicious node returns a record with wrong Record.key
    let record = await victim.getValue(requestedKey, quorumOverride = Opt.some(1))

    # getValue should fail because the only response has mismatched key
    check:
      record.isErr()
      victim.containsNoData(requestedKey)

  asyncTest "GET_VALUE rejects response without record":
    let
      (victimSwitch, victim) =
        await setupKadSwitch(PermissiveValidator(), CandSelector())
      (maliciousSwitch, malicious) = await setupMockKadSwitch(
        PermissiveValidator(), CandSelector(), getValueResponse = EmptyRecord
      )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victim, malicious)

    let requestedKey = victim.rtable.selfId
    check victim.containsNoData(requestedKey)

    # When victim calls getValue, malicious node returns a response without record
    let record = await victim.getValue(requestedKey, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      victim.containsNoData(requestedKey)

  asyncTest "GET_VALUE rejects record without value":
    let
      (victimSwitch, victim) =
        await setupKadSwitch(PermissiveValidator(), CandSelector())
      (maliciousSwitch, malicious) = await setupMockKadSwitch(
        PermissiveValidator(), CandSelector(), getValueResponse = NoValue
      )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victim, malicious)

    let requestedKey = victim.rtable.selfId
    check victim.containsNoData(requestedKey)

    # When victim calls getValue, malicious node returns a record without value
    let record = await victim.getValue(requestedKey, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      victim.containsNoData(requestedKey)
