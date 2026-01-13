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
import chronos, chronicles, sets
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

proc getPeersFromRoutingTable*(kad: KadDHT): seq[PeerId] =
  var peersInTable: seq[PeerId]
  for bucket in kad.rtable.buckets:
    for entry in bucket.peers:
      peersInTable.add(entry.nodeId.toPeerId().get())
  peersInTable

suite "KadDHT Get":
  teardown:
    checkTrackers()

  asyncTest "Get from peer":
    var (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)

    check:
      containsData(kad1, key, value)
      containsNoData(kad2, key)

    discard await kad2.getValue(key, quorumOverride = Opt.some(1))

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Get value that is locally present":
    var (switch, kad) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await switch.stop()

    let
      key = kad.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad.dataTable.insert(key, value, $times.now().utc)

    check:
      containsData(kad, key, value)
      (await kad.getValue(key, quorumOverride = Opt.some(1))).get().value == value

  asyncTest "Divergent getVal responses from peers":
    var (switch2, kad2) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = await setupKadSwitch(
      DefaultEntryValidator(),
      DefaultEntrySelector(),
      @[
        (switch2.peerInfo.peerId, switch2.peerInfo.addrs),
        (switch3.peerInfo.peerId, switch3.peerInfo.addrs),
        (switch4.peerInfo.peerId, switch4.peerInfo.addrs),
        (switch5.peerInfo.peerId, switch5.peerInfo.addrs),
      ],
    )

    defer:
      await allFutures(
        switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop()
      )

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad1.findNode(kad3.rtable.selfId)
    discard await kad1.findNode(kad4.rtable.selfId)
    discard await kad1.findNode(kad5.rtable.selfId)

    let
      key = kad4.rtable.selfId
      bestValue = @[1.byte, 2, 3, 4, 5]
      worstValue = @[1.byte, 2, 3, 4, 6]

    kad2.dataTable.insert(key, bestValue, $times.now().utc)
    kad3.dataTable.insert(key, worstValue, $times.now().utc)
    kad4.dataTable.insert(key, bestValue, $times.now().utc)
    kad5.dataTable.insert(key, bestValue, $times.now().utc)

    check:
      containsNoData(kad1, key)
      containsData(kad2, key, bestValue)
      containsData(kad3, key, worstValue)
      containsData(kad4, key, bestValue)
      containsData(kad5, key, bestValue)

    discard await kad1.getValue(key, quorumOverride = Opt.some(3))

    # now all have bestvalue
    check:
      containsData(kad1, key, bestValue)
      containsData(kad2, key, bestValue)
      containsData(kad3, key, bestValue)
      containsData(kad4, key, bestValue)
      containsData(kad5, key, bestValue)

  asyncTest "Could not achieve quorum":
    var (switch2, kad2) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[
        (switch2.peerInfo.peerId, switch2.peerInfo.addrs),
        (switch3.peerInfo.peerId, switch3.peerInfo.addrs),
        (switch4.peerInfo.peerId, switch4.peerInfo.addrs),
        (switch5.peerInfo.peerId, switch5.peerInfo.addrs),
      ],
    )
    defer:
      await allFutures(
        switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop()
      )

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad1.findNode(kad3.rtable.selfId)
    discard await kad1.findNode(kad4.rtable.selfId)
    discard await kad1.findNode(kad5.rtable.selfId)

    let
      key = kad4.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key, value, $times.now().utc)

    check:
      containsNoData(kad1, key)
      containsData(kad2, key, value)
      containsNoData(kad3, key)
      containsNoData(kad4, key)
      containsNoData(kad5, key)

    let getValueRes = (await kad1.getValue(key))
    check getValueRes.isErr()
    check getValueRes.error() ==
      "Not enough valid records to achieve quorum, needed 5 got 1"

  asyncTest "Update peers with empty values":
    var (switch2, kad2) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      await setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[
        (switch2.peerInfo.peerId, switch2.peerInfo.addrs),
        (switch3.peerInfo.peerId, switch3.peerInfo.addrs),
        (switch4.peerInfo.peerId, switch4.peerInfo.addrs),
        (switch5.peerInfo.peerId, switch5.peerInfo.addrs),
      ],
    )
    defer:
      await allFutures(
        switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop()
      )

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad1.findNode(kad3.rtable.selfId)
    discard await kad1.findNode(kad4.rtable.selfId)
    discard await kad1.findNode(kad5.rtable.selfId)

    let
      key = kad4.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key, value, $times.now().utc)

    check:
      containsNoData(kad1, key)
      containsData(kad2, key, value)
      containsNoData(kad3, key)
      containsNoData(kad4, key)
      containsNoData(kad5, key)

    # 1 is enough to make a decision
    discard await kad1.getValue(key, quorumOverride = Opt.some(1))

    # peers are updated
    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)
      containsData(kad3, key, value)
      containsData(kad4, key, value)
      containsData(kad5, key, value)

  asyncTest "Get updates routing table with closerPeers":
    var (switch1, kad1) = await setupKadSwitch(
      PermissiveValidator(), CandSelector(), @[], chronos.seconds(1), chronos.seconds(1)
    )
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    var (switch3, kad3) = await setupMockKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
      chronos.seconds(1),
      chronos.seconds(1),
    )

    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    # kad3 tries to get key from 1 when 2 does not have key (only 1 on routing table)
    discard await kad3.getValue(key, quorumOverride = Opt.some(1))
    check kad3.getPeersFromRoutingTable().toHashSet() ==
      @[switch1.peerInfo.peerId, switch2.peerInfo.peerId].toHashSet()

    # kad3 tries to get key from 1 when 2 has key (1 and 2 on routing table)
    kad2.dataTable.insert(key, value, $times.now().utc)
    discard await kad3.getValue(key, quorumOverride = Opt.some(1))
    check kad3.getPeersFromRoutingTable().toHashSet() ==
      @[switch1.peerInfo.peerId, switch2.peerInfo.peerId].toHashSet()

  asyncTest "Quorum handling is ignored if quorum is 0 or 1":
    # three peers
    var (switch1, kad1) = await setupKadSwitch(
      PermissiveValidator(), CandSelector(), @[], chronos.seconds(1), chronos.seconds(1)
    )
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    var (switch3, kad3) = await setupMockKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
      chronos.seconds(1),
      chronos.seconds(1),
    )

    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    let
      key = kad1.rtable.selfId
      value1 = @[1.byte, 1, 1, 1, 1]
      value2 = @[2.byte, 2, 2, 2, 2]

    # kad2 and kad3 have different values than kad1
    kad1.dataTable.insert(key, value1, $times.now().utc)
    kad2.dataTable.insert(key, value2, $times.now().utc)
    kad3.dataTable.insert(key, value2, $times.now().utc)

    # but when quorum is 0 or 1 we ignore remote values and use local value

    check:
      (await kad1.getValue(key, quorumOverride = Opt.some(0))).get().value == value1
      (await kad1.getValue(key, quorumOverride = Opt.some(1))).get().value == value1
