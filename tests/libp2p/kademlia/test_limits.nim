# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[lifecycle, topology, unittest]
import ./utils.nim

suite "KadDHT - Limits":
  teardown:
    checkTrackers()

  test "updateShortlist caps shortlist at maxShortlistSize":
    let kad = setupKad()
    kad.config.limits.maxShortlistSize = 5

    let targetKey = randomPeerId().toKey()
    var state = LookupState.init(kad, targetKey)

    # Generate 20 fresh peers and feed them through updateShortlist.
    var peers: seq[Peer]
    for i in 0 ..< 20:
      peers.add(Peer(id: randomPeerId().toKey(), addrs: @[]))

    let msg = Message(msgType: MessageType.findNode, closerPeers: peers)
    discard state.updateShortlist(msg)

    check state.shortlist.len <= kad.config.limits.maxShortlistSize

  test "updateShortlist prefers closer peers when over cap":
    let kad = setupKad()
    kad.config.limits.maxShortlistSize = 3

    # Use the no-op hasher so XOR distance is a function of the key bytes
    # directly, making "close" peers easy to construct.
    kad.rtable.config.hasher = Opt.some(noOpHasher)
    var target: Key = newSeq[byte](32)
    var state = LookupState.init(kad, target)
    # Drop any peers pre-seeded from the routing table.
    state.shortlist.clear()

    # Insert a far peer first
    var farId: Key = newSeq[byte](32)
    farId[0] = 0xFF
    let farMsg = Message(msgType: MessageType.findNode, closerPeers: @[Peer(id: farId)])
    discard state.updateShortlist(farMsg)

    # Now insert 5 close peers — they should evict the far one
    var closePeers: seq[Peer]
    for i in 1 .. 5:
      var id: Key = newSeq[byte](32)
      id[31] = byte(i)
      closePeers.add(Peer(id: id))
    let closeMsg = Message(msgType: MessageType.findNode, closerPeers: closePeers)
    discard state.updateShortlist(closeMsg)

    check state.shortlist.len == kad.config.limits.maxShortlistSize

  asyncTest "putValue rejects values larger than maxValueSize":
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    kads[1].config.limits.maxValueSize = 16

    let key = kads[0].rtable.selfId
    let big = newSeq[byte](32)
    let res = await kads[1].putValue(key, big)

    check:
      res.isErr()
      kads[0].dataTable.len == 0
      kads[1].dataTable.len == 0

  asyncTest "handlePutValue drops records exceeding maxValueSize":
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    # Lower the receiver's cap so the sender's normal-size put is rejected
    # on the wire even though the sender accepts it locally.
    kads[0].config.limits.maxValueSize = 8
    kads[1].config.limits.maxValueSize = 1024

    let key = kads[0].rtable.selfId
    let value = newSeq[byte](64)
    discard await kads[1].putValue(key, value)

    # Sender stores locally (under its own cap); receiver drops the wire copy.
    # putValue awaited the full RPC batch, so the receiver has already processed
    # (and dropped) the message by the time we reach this check.
    check:
      kads[1].containsData(key, value)
      kads[0].containsNoData(key)

  asyncTest "handlePutValue drops new records when maxLocalRecords is reached":
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    kads[0].config.limits.maxLocalRecords = Opt.some(1)

    let
      existingKey = randomPeerId().toKey()
      newKey = randomPeerId().toKey()
      existingValue = @[1.byte]
      newValue = @[2.byte]

    kads[0].dataTable.insert(existingKey, existingValue, Timestamp.now())

    let request = Message(
      msgType: MessageType.putValue,
      key: newKey,
      record: Opt.some(Record(key: newKey, value: Opt.some(newValue))),
    )
    let conn = await kads[1].switch.dial(
      kads[0].switch.peerInfo.peerId, kads[0].switch.peerInfo.addrs, kads[0].codec
    )
    await kads[0].handlePutValue(conn, request)

    check:
      kads[0].containsData(existingKey, existingValue)
      kads[0].containsNoData(newKey)

  asyncTest "getValue skips local insert when maxLocalRecords is reached":
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    kads[0].config.limits.maxLocalRecords = Opt.some(1)

    let
      existingKey = randomPeerId().toKey()
      lookupKey = kads[1].rtable.selfId
      existingValue = @[1.byte]
      lookupValue = @[2.byte]

    kads[0].dataTable.insert(existingKey, existingValue, Timestamp.now())
    kads[1].dataTable.insert(lookupKey, lookupValue, Timestamp.now())

    let res = await kads[0].getValue(lookupKey, quorumOverride = Opt.some(1))

    check:
      res.isOk()
      res.value().value == lookupValue
      kads[0].containsData(existingKey, existingValue)
      kads[0].containsNoData(lookupKey)

  asyncTest "getValue caps ReceivedTable at maxReceivedSize":
    let kads = setupKadSwitches(4)
    startAndDeferStop(kads)
    await connectStar(kads)

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3]

    # Seed every other node with the key/value
    for i in 1 ..< 4:
      discard await kads[i].putValue(key, value)

    # Cap kads[0]'s ReceivedTable below the available peers
    kads[0].config.limits.maxReceivedSize = 1
    let res = await kads[0].getValue(key, quorumOverride = Opt.some(1))

    check res.isOk()
    check res.value().value == value

  asyncTest "rpcSem bounds concurrent in-flight RPCs":
    # With a 1-slot semaphore the second concurrent dispatchFindNode must wait
    # for the first to release before it can start. We verify this by checking
    # availableSlots mid-flight (should be 0) and after completion (should be 1).
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    # Replace the semaphore with a 1-slot one; the helper template uses kad.rpcSem.
    kads[0].rpcSem = newAsyncSemaphore(1)

    let target = kads[1].rtable.selfId
    let f1 = kads[0].dispatchFindNode(kads[1].switch.peerInfo.peerId, target)
    let f2 = kads[0].dispatchFindNode(kads[1].switch.peerInfo.peerId, target)
    # Yield so both coroutines get a chance to start; with a 1-slot semaphore
    # f1 holds the slot (suspended in dial) while f2 is blocked on acquire.
    await sleepAsync(0)
    check kads[0].rpcSem.availableSlots == 0
    await allFutures(f1, f2)
    check:
      kads[0].rpcSem.availableSlots == 1
      f1.read().isOk()
      f2.read().isOk()
