{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import unittest2

import ../libp2p/protocols/connectivity/dcutr/core as dcore
import ../libp2p/protocols/connectivity/dcutr/[client, server]
from ../libp2p/protocols/connectivity/autonat/core import NetworkReachability
import ../libp2p/builders
import ../libp2p/utils/future
import ./helpers
import ./stubs/switchstub

suite "Dcutr":
  teardown:
    checkTrackers()

  asyncTest "Connect msg Encode / Decode":
    let addrs =
      @[
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
      ]
    let connectMsg = DcutrMsg(msgType: MsgType.Connect, addrs: addrs)

    let pb = connectMsg.encode()
    let connectMsgDecoded = DcutrMsg.decode(pb.buffer)

    check connectMsg == connectMsgDecoded

  asyncTest "Sync msg Encode / Decode":
    let addrs =
      @[
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
      ]
    let syncMsg = DcutrMsg(msgType: MsgType.Sync, addrs: addrs)

    let pb = syncMsg.encode()
    let syncMsgDecoded = DcutrMsg.decode(pb.buffer)

    check syncMsg == syncMsgDecoded

  asyncTest "DCUtR establishes a new connection":
    let behindNATSwitch = newStandardSwitch()
    let publicSwitch = newStandardSwitch()

    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    expect CatchableError:
      # we can't hole punch when both peers are in the same machine. This means that the simultaneous dialings will result
      # in two connections attemps, instead of one. This dial is going to fail because the dcutr client is acting as the
      # tcp simultaneous incoming upgrader in the dialer which works only in the simultaneous open case.
      await DcutrClient
      .new()
      .startSync(
        behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
      )
      .wait(300.millis)

    checkUntilTimeout:
      # we still expect a new connection to be open by the receiver peer acting as the dcutr server
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 2

    await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

  template ductrClientTest(
      behindNATSwitch: Switch, publicSwitch: Switch, body: untyped
  ) =
    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    body

    checkUntilTimeout:
      # we still expect a new connection to be open by the receiver peer acting as the dcutr server
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 2

    await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

  asyncTest "Client connect timeout":
    proc connectTimeoutProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async.} =
      await sleepAsync(100.millis)

    let behindNATSwitch = SwitchStub.new(newStandardSwitch(), connectTimeoutProc)
    let publicSwitch = newStandardSwitch()
    ductrClientTest(behindNATSwitch, publicSwitch):
      try:
        let client = DcutrClient.new(connectTimeout = 5.millis)
        await client.startSync(
          behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
        )
      except DcutrError as err:
        check err.parent of AsyncTimeoutError

  asyncTest "All client connect attempts fail":
    proc connectErrorProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async.} =
      raise newException(CatchableError, "error")

    let behindNATSwitch = SwitchStub.new(newStandardSwitch(), connectErrorProc)
    let publicSwitch = newStandardSwitch()
    ductrClientTest(behindNATSwitch, publicSwitch):
      try:
        let client = DcutrClient.new(connectTimeout = 5.millis)
        await client.startSync(
          behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
        )
      except DcutrError as err:
        check err.parent of AllFuturesFailedError

  proc ductrServerTest(connectStub: connectStubType) {.async.} =
    let behindNATSwitch = newStandardSwitch()
    let publicSwitch = SwitchStub.new(newStandardSwitch())

    let dcutrProto = Dcutr.new(publicSwitch, connectTimeout = 5.millis)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    publicSwitch.connectStub = connectStub

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    expect CatchableError:
      # we can't hole punch when both peers are in the same machine. This means that the simultaneous dialings will result
      # in two connections attemps, instead of one. This dial is going to fail because the dcutr client is acting as the
      # tcp simultaneous incoming upgrader in the dialer which works only in the simultaneous open case.
      await DcutrClient
      .new()
      .startSync(
        behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
      )
      .wait(300.millis)

    checkUntilTimeout:
      # we still expect a new connection to be open by the receiver peer acting as the dcutr server
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 1

    await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

  asyncTest "DCUtR server timeout when establishing a new connection":
    proc connectProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async.} =
      await sleepAsync(100.millis)

    await ductrServerTest(connectProc)

  asyncTest "DCUtR server error when establishing a new connection":
    proc connectProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async.} =
      raise newException(CatchableError, "error")

    await ductrServerTest(connectProc)

  test "should return valid TCP/IP and TCP/DNS addresses only":
    let testAddrs =
      @[
        MultiAddress.init("/ip4/192.0.2.1/tcp/1234").tryGet(),
        MultiAddress
        .init(
          "/ip4/203.0.113.5/tcp/5678/p2p/QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N"
        )
        .tryGet(),
        MultiAddress.init("/ip6/::1/tcp/9012").tryGet(),
        MultiAddress
        .init(
          "/dns4/example.com/tcp/3456/p2p/QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N"
        )
        .tryGet(),
        MultiAddress.init("/ip4/198.51.100.42/udp/7890").tryGet(),
      ]

    let expected =
      @[
        MultiAddress.init("/ip4/192.0.2.1/tcp/1234").tryGet(),
        MultiAddress.init("/ip4/203.0.113.5/tcp/5678").tryGet(),
        MultiAddress.init("/ip6/::1/tcp/9012").tryGet(),
        MultiAddress.init("/dns4/example.com/tcp/3456").tryGet(),
      ]

    let result = getHolePunchableAddrs(testAddrs)

    check result == expected
