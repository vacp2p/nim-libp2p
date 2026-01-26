# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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

  asyncTest "Get value rejects record where Record.key does not match requested key":
    let kad = await setupKadSwitch()

    let
      key = kad.rtable.selfId
      wrongKey = @[1.byte, 1, 1, 1]
      getValueResponse = Opt.some(
        Message(
          msgType: MessageType.getValue,
          key: key,
          record: Opt.some(
            protobuf.Record(
              key: wrongKey, # get value response with mismatched recored key
              value: Opt.some(@[1.byte, 2, 3, 4]),
              timeReceived: Opt.some($times.now().utc),
            )
          ),
          closerPeers: @[],
        )
      )

    let mockKad = await setupMockKadSwitch(getValueResponse = getValueResponse)
    defer:
      await stopNodes(@[kad, mockKad])

    connectNodes(kad, mockKad)

    check kad.containsNoData(key)

    # Mock node returns a record with wrong Record.key
    let record = await kad.getValue(key, quorumOverride = Opt.some(1))

    # getValue should fail because the only response has mismatched key
    check:
      record.isErr()
      kad.containsNoData(key)
      kad.containsNoData(wrongKey)

  asyncTest "Get value rejects response without record":
    let kad = await setupKadSwitch()

    let
      key = kad.rtable.selfId
      getValueResponse = Opt.some(
        Message(
          msgType: MessageType.getValue,
          key: key,
          record: Opt.none(protobuf.Record), # get value response with empty record
          closerPeers: @[],
        )
      )

    let mockKad = await setupMockKadSwitch(getValueResponse = getValueResponse)
    defer:
      await stopNodes(@[kad, mockKad])

    connectNodes(kad, mockKad)

    check kad.containsNoData(key)

    # Mock node returns a response without record
    let record = await kad.getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      kad.containsNoData(key)

  asyncTest "Get value rejects record without value":
    let kad = await setupKadSwitch()

    let
      key = kad.rtable.selfId
      getValueResponse = Opt.some(
        Message(
          msgType: MessageType.getValue,
          key: key,
          record: Opt.some(
            protobuf.Record(
              key: key,
              value: Opt.none(seq[byte]), # get value response with empty record value
              timeReceived: Opt.some($times.now().utc),
            )
          ),
          closerPeers: @[],
        )
      )

    let mockKad = await setupMockKadSwitch(getValueResponse = getValueResponse)
    defer:
      await stopNodes(@[kad, mockKad])

    connectNodes(kad, mockKad)

    check kad.containsNoData(key)

    # Mock node returns a record without value
    let record = await kad.getValue(key, quorumOverride = Opt.some(1))

    check:
      record.isErr()
      kad.containsNoData(key)

  asyncTest "Get value succeeds with some peers returning mismatched keys":
    let kads = await setupKadSwitches(3)

    let
      key = kads[0].rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]
      wrongKey = @[1.byte, 1, 1, 1]
      getValueResponse = Opt.some(
        Message(
          msgType: MessageType.getValue,
          key: key,
          record: Opt.some(
            protobuf.Record(
              key: wrongKey, # get value response with mismatched recored key
              value: Opt.some(value),
              timeReceived: Opt.some($times.now().utc),
            )
          ),
          closerPeers: @[],
        )
      )

    let mockKad = await setupMockKadSwitch(getValueResponse = getValueResponse)
    defer:
      await stopNodes(kads & mockKad)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])
    connectNodes(kads[0], mockKad)

    # Compliant nodes have valid records
    kads[1].dataTable.insert(key, value, $times.now().utc)
    kads[2].dataTable.insert(key, value, $times.now().utc)
    # mockKad will return mismatched key

    let record = await kads[0].getValue(key, quorumOverride = Opt.some(2))

    check:
      record.isOk()
      record.get().value == value
      mockKad.containsData(key, value) # mock node was updated

  asyncTest "Get value rejects records that fail validation":
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

  asyncTest "Get value succeeds when some peers are offline":
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

  asyncTest "Get value fails when too many peers are offline":
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

  asyncTest "Get value retrieves binary data with null and high bytes":
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
