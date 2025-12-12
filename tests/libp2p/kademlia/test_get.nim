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
import chronos, chronicles
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "KadDHT Get":
  teardown:
    checkTrackers()

  asyncTest "Get from peer":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
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

    kad2.config.quorum = 1
    discard await kad2.getValue(key)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Get value that is locally present":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
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
    kad2.dataTable.insert(key, value, $times.now().utc)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

    discard await kad2.getValue(key)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Divergent getVal responses from peers":
    var (switch2, kad2) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = setupKadSwitch(
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

    kad1.config.quorum = 3
    discard await kad1.getValue(key)

    # now all have bestvalue
    check:
      containsData(kad1, key, bestValue)
      containsData(kad2, key, bestValue)
      containsData(kad3, key, bestValue)
      containsData(kad4, key, bestValue)
      containsData(kad5, key, bestValue)

  asyncTest "Could not achieve quorum":
    var (switch2, kad2) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = setupKadSwitch(
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
    check getValueRes.error() == "Not enough valid records to achieve quorum"

  asyncTest "Update peers with empty values":
    var (switch2, kad2) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch1, kad1) = setupKadSwitch(
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
    kad1.config.quorum = 1

    discard await kad1.getValue(key)

    # peers are updated
    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)
      containsData(kad3, key, value)
      containsData(kad4, key, value)
      containsData(kad5, key, value)
