# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[times, tables], chronos
import ../../../libp2p/[protocols/kademlia, switch, builders, multihash]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Put":
  teardown:
    checkTrackers()

  asyncTest "PUT_VALUE stores record at both sender and target peer":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    # Both nodes start with empty data tables
    check:
      kads[0].dataTable.len == 0
      kads[1].dataTable.len == 0

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kads[1].putValue(key, value)

    # After putValue, both nodes should have the record
    check:
      kads[0].containsData(key, value)
      kads[1].containsData(key, value)

  asyncTest "PUT_VALUE requires validation on both sender and receiver":
    let kads = await setupKadSwitches(2, validator = RestrictiveValidator())
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    # Both validators reject -> putValue fails, nothing stored
    check:
      (await kads[1].putValue(key, value)).isErr()
      kads[0].dataTable.len == 0

    # Only receiver accepts -> sender validation still fails
    kads[0].config.validator = PermissiveValidator()
    check:
      (await kads[1].putValue(key, value)).isErr()
      kads[0].dataTable.len == 0

    # Both validators accept -> putValue succeeds
    kads[1].config.validator = PermissiveValidator()
    check:
      (await kads[1].putValue(key, value)).isOk()
      kads[0].containsData(key, value)
      kads[1].containsData(key, value)

  asyncTest "PUT_VALUE sets timeReceived in RFC3339 format":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kads[1].putValue(key, value)

    # Parse the stored timestamp
    let storedTime: string = kads[0].dataTable[key].time
    let now = times.now().utc
    let parsed = storedTime.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # Timestamp should be very recent (within 2 seconds of now)
    let elapsed = now - parsed
    check elapsed < times.initDuration(seconds = 2)

  asyncTest "PUT_VALUE uses selector to choose best value":
    let kads = await setupKadSwitches(2, selector = OthersSelector())
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    let emptyVal: seq[byte] = @[]

    # Store initial value
    discard await kads[0].putValue(key, value)
    check kads[1].containsData(key, value)

    # With OthersSelector, new value is rejected in favor of existing
    discard await kads[0].putValue(key, emptyVal)
    check kads[1].containsData(key, value)

    # Switch to CandSelector (accepts first/new value)
    kads[0].config.selector = CandSelector()
    kads[1].config.selector = CandSelector()

    # Now the new value replaces the old one
    discard await kads[0].putValue(key, emptyVal)
    check kads[1].containsData(key, emptyVal)

  asyncTest "PUT_VALUE rejects mismatched Message.key and Record.key":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    # Create two different keys to simulate mismatch
    let msgKey = MultiHash.digest("sha2-256", [byte 0, 1, 2, 3, 4]).get().toKey()
    let recordKey = MultiHash.digest("sha2-256", [byte 0, 0, 0, 0, 0]).get().toKey()
    check msgKey != recordKey

    # Build a malformed PUT_VALUE message with mismatched keys
    let msg = Message(
      msgType: MessageType.putValue,
      key: msgKey,
      record: Opt.some(Record(key: recordKey, value: Opt.some(@[1.byte, 2, 3, 4, 5]))),
    )

    # Send directly via handlePutValue to test the validation logic
    let conn = await kads[1].switch.dial(
      kads[0].switch.peerInfo.peerId, kads[0].switch.peerInfo.addrs, KadCodec
    )

    await kads[0].handlePutValue(conn, msg)

    # Neither key should have data stored - the request should be rejected
    check:
      kads[0].containsNoData(msgKey)
      kads[0].containsNoData(recordKey)

  asyncTest "PUT_VALUE response echoes request":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    # Build the PUT_VALUE request message
    let request = Message(
      msgType: MessageType.putValue,
      key: key,
      record: Opt.some(Record(key: key, value: Opt.some(value))),
    )

    let conn = await kads[1].switch.dial(
      kads[0].switch.peerInfo.peerId, kads[0].switch.peerInfo.addrs, KadCodec
    )

    # Call handlePutValue directly - it writes the response to conn
    await kads[0].handlePutValue(conn, request)

    # Read the echoed response
    let responseBytes = await conn.readLp(MaxMsgSize)
    let response = Message.decode(responseBytes).value()

    # Response should be identical to the request
    check response == request
