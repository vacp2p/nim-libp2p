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
import ./utils

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
    let (victimSwitch, victimKad) =
      await setupKadSwitch(PermissiveValidator(), CandSelector())

    # Get value response with mismatched recored key
    let
      key = victimKad.rtable.selfId
      wrongKey = @[1.byte, 1, 1, 1]
      mockMessage = Message(
        msgType: MessageType.getValue,
        key: key,
        record: Opt.some(
          protobuf.Record(
            key: wrongKey,
            value: Opt.some(@[1.byte, 2, 3, 4]),
            timeReceived: Opt.some($times.now().utc),
          )
        ),
        closerPeers: @[],
      )

    let (maliciousSwitch, maliciousKad) = await setupMockKadSwitch(
      PermissiveValidator(), CandSelector(), getValueResponse = Opt.some(mockMessage)
    )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victimKad, maliciousKad)

    check victimKad.containsNoData(key)

    # When victim calls getValue, malicious node returns a record with wrong Record.key
    let record = await victimKad.getValue(key, quorumOverride = Opt.some(1))

    # getValue should fail because the only response has mismatched key
    check:
      record.isErr()
      victimKad.containsNoData(key)
      victimKad.containsNoData(wrongKey)

  asyncTest "GET_VALUE rejects response without record":
    let (victimSwitch, victimKad) =
      await setupKadSwitch(PermissiveValidator(), CandSelector())

    # Get value response with empty record
    let
      key = victimKad.rtable.selfId
      mockMessage = Message(
        msgType: MessageType.getValue,
        key: key,
        record: Opt.none(protobuf.Record),
        closerPeers: @[],
      )

    let (maliciousSwitch, maliciousKad) = await setupMockKadSwitch(
      PermissiveValidator(), CandSelector(), getValueResponse = Opt.some(mockMessage)
    )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victimKad, maliciousKad)

    check victimKad.containsNoData(key)

    # When victim calls getValue, malicious node returns a response without record
    let record = await victimKad.getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      victimKad.containsNoData(key)

  asyncTest "GET_VALUE rejects record without value":
    let (victimSwitch, victimKad) =
      await setupKadSwitch(PermissiveValidator(), CandSelector())

    # Get value response with empty record value
    let
      key = victimKad.rtable.selfId
      mockMessage = Message(
        msgType: MessageType.getValue,
        key: key,
        record: Opt.some(
          protobuf.Record(
            key: key,
            value: Opt.none(seq[byte]),
            timeReceived: Opt.some($times.now().utc),
          )
        ),
        closerPeers: @[],
      )

    let (maliciousSwitch, maliciousKad) = await setupMockKadSwitch(
      PermissiveValidator(), CandSelector(), getValueResponse = Opt.some(mockMessage)
    )
    defer:
      await victimSwitch.stop()
      await maliciousSwitch.stop()

    connectNodes(victimKad, maliciousKad)

    check victimKad.containsNoData(key)

    # When victim calls getValue, malicious node returns a record without value
    let record = await victimKad.getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      victimKad.containsNoData(key)

  asyncTest "GET_VALUE succeeds with some peers returning mismatched keys":
    let kads = await setupKadSwitches(3)

    # Get value response with mismatched recored key
    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]
      wrongKey = @[1.byte, 1, 1, 1]
      mockMessage = Message(
        msgType: MessageType.getValue,
        key: key,
        record: Opt.some(
          protobuf.Record(
            key: wrongKey,
            value: Opt.some(@[1.byte, 2, 3, 4]),
            timeReceived: Opt.some($times.now().utc),
          )
        ),
        closerPeers: @[],
      )

    let (maliciousSwitch, maliciousKad) = await setupMockKadSwitch(
      PermissiveValidator(), CandSelector(), getValueResponse = Opt.some(mockMessage)
    )
    defer:
      await stopNodes(kads)
      await maliciousSwitch.stop()

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[0], maliciousKad)

    # Good nodes have valid records
    kads[1].dataTable.insert(key, value, $times.now().utc)
    kads[2].dataTable.insert(key, value, $times.now().utc)
    # maliciousKad will return mismatched key

    let record = await kads[0].getValue(key, quorumOverride = Opt.some(2))

    check:
      record.isOk()
      record.get().value == value
      maliciousKad.containsData(key, value) # malicious node was updated

  asyncTest "GET_VALUE rejects records that fail validation":
    # Use RestrictiveValidator which rejects all records
    let kads = await setupKadSwitches(2, RestrictiveValidator(), CandSelector())
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    # Insert directly into dataTable
    kads[1].dataTable.insert(key, value, $times.now().utc)

    check:
      kads[1].containsData(key, value)
      kads[0].containsNoData(key)

    # getValue should fail because RestrictiveValidator rejects the record
    let record = await kads[0].getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      kads[0].containsNoData(key)

  asyncTest "GET_VALUE succeeds when some peers are offline":
    let kads = await setupKadSwitches(4)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    # All peers have the record
    kads[1].dataTable.insert(key, value, $times.now().utc)
    kads[2].dataTable.insert(key, value, $times.now().utc)
    kads[3].dataTable.insert(key, value, $times.now().utc)

    # Stop one peer before query
    await kads[3].switch.stop()

    defer:
      await kads[0].switch.stop()
      await kads[1].switch.stop()
      await kads[2].switch.stop()

    # Query should still succeed with remaining peers (quorum=2)
    let record = await kads[0].getValue(key, quorumOverride = Opt.some(2))

    check:
      record.isOk()
      record.get().value == value

  asyncTest "GET_VALUE fails when too many peers are offline":
    let kads = await setupKadSwitches(4)

    connectNodesStar(kads)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    # All peers have the record
    kads[1].dataTable.insert(key, value, $times.now().utc)
    kads[2].dataTable.insert(key, value, $times.now().utc)
    kads[3].dataTable.insert(key, value, $times.now().utc)

    # Stop two peers before query
    await kads[2].switch.stop()
    await kads[3].switch.stop()

    defer:
      await kads[0].switch.stop()
      await kads[1].switch.stop()

    # Query should fail - need quorum of 3 but only 1 peer available
    let record = await kads[0].getValue(key, quorumOverride = Opt.some(3))

    check:
      record.isErr()

  asyncTest "GET_VALUE retrieves binary data with null and high bytes":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key = kads[0].rtable.selfId
      value = @[0.byte, 0xFF, 0, 0xFF]

    kads[0].dataTable.insert(key, value, $times.now().utc)

    let record = await kads[1].getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isOk()
      record.get().value == value
