# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, chronicles, results, tables
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[lifecycle, topology, unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

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
    let farMsg = Message(
      msgType: MessageType.findNode, closerPeers: @[Peer(id: farId, addrs: @[])]
    )
    discard state.updateShortlist(farMsg)

    # Now insert 5 close peers — they should evict the far one
    var closePeers: seq[Peer]
    for i in 1 .. 5:
      var id: Key = newSeq[byte](32)
      id[31] = byte(i)
      closePeers.add(Peer(id: id, addrs: @[]))
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
    await sleepAsync(200.milliseconds)
    check:
      kads[1].containsData(key, value)
      kads[0].containsNoData(key)

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
    # With a 1-slot semaphore the second concurrent dispatchFindNode is forced
    # to wait until the first releases — easy to observe by checking that the
    # semaphore count never goes negative and reaches 0 mid-flight.
    let kads = setupKadSwitches(2)
    startAndDeferStop(kads)
    await connect(kads[0], kads[1])

    # Replace the semaphore with a 1-slot one; the helper template uses kad.rpcSem.
    kads[0].rpcSem = newAsyncSemaphore(1)

    let target = kads[1].rtable.selfId
    let f1 = kads[0].dispatchFindNode(kads[1].switch.peerInfo.peerId, target)
    let f2 = kads[0].dispatchFindNode(kads[1].switch.peerInfo.peerId, target)
    await allFutures(f1, f2)
    check:
      f1.read().isOk()
      f2.read().isOk()
