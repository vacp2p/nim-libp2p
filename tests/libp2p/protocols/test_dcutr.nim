# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import stew/byteutils
import ../../../libp2p/protocols/connectivity/dcutr/core as dcore
import ../../../libp2p/protocols/connectivity/dcutr/[client, server]
from ../../../libp2p/protocols/connectivity/autonat/types import NetworkReachability
import ../../../libp2p/connmanager
import ../../../libp2p/[builders, utils/future]
import ../../stubs/switchstub
import ../../tools/[unittest, switch_builder, multiaddress]

proc makeSwitch(address: MultiAddress = TcpAutoAddress): Switch =
  return makeStandardSwitch(address)

suite "Dcutr":
  teardown:
    checkTrackers()

  asyncTest "Connect msg Encode / Decode":
    const pbHexReference = "08641208040000000006000012080400000000060000"

    let addrs = @[
      MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
      MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    ]
    let connectMsg = DcutrMsg(msgType: MsgType.Connect, addrs: addrs)

    let pb = connectMsg.encode()
    let connectMsgDecoded = DcutrMsg.decode(pb).valueOr:
      raise newException(DcutrError, "Failed to decode a Connect message.")

    check connectMsg == connectMsgDecoded
    check pb == hexToSeqByte(pbHexReference)

  asyncTest "Sync msg Encode / Decode":
    const pbHexReference = "08ac021208040000000006000012080400000000060000"

    let addrs = @[
      MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
      MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    ]
    let syncMsg = DcutrMsg(msgType: MsgType.Sync, addrs: addrs)

    let pb = syncMsg.encode()
    let syncMsgDecoded = DcutrMsg.decode(pb).valueOr:
      raise newException(DcutrError, "Failed to decode a Sync message.")

    check syncMsg == syncMsgDecoded
    check pb == hexToSeqByte(pbHexReference)

  asyncTest "DCUtR establishes a new connection":
    let behindNATSwitch = makeSwitch()
    let publicSwitch = makeSwitch()

    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())
    defer:
      await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    expect AsyncTimeoutError:
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

  asyncTest "DCUtR establishes a new QUIC connection":
    let behindNATSwitch = makeSwitch(QuicAutoAddress)
    let publicSwitch = makeSwitch(QuicAutoAddress)

    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())
    defer:
      await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )
    let initialConnCount =
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId)
    check initialConnCount == 1

    let directConnSeen =
      Future[void].Raising([CancelledError]).init("dcutr direct connection seen")

    proc onDirectConn(
        peerId: PeerId, event: ConnEvent
    ): Future[void] {.async: (raises: [CancelledError]).} =
      if peerId == publicSwitch.peerInfo.peerId and
          behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) >
          initialConnCount:
        directConnSeen.completeOnce()
    
    # use event handler to wait-and-assert exact moment when condition 
    # (publicSwitch has connected to behindNATSwitch) is satisfied 
    # instead of polling, as polling can miss a short-lived true state
    behindNATSwitch.connManager.addConnEventHandler(
      onDirectConn, ConnEventKind.Connected
    )

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    await DcutrClient
      .new(connectTimeout = 5.seconds)
      .startSync(
        behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
      )
      .wait(10.seconds)

    check await directConnSeen.withTimeout(10.seconds)

  template ductrClientTest(
      behindNATSwitch: Switch, publicSwitch: Switch, body: untyped
  ) =
    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())
    defer:
      await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    body

    checkUntilTimeout:
      # we still expect a new connection to be open by the receiver peer acting as the dcutr server
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 2

  asyncTest "Client connect timeout":
    proc connectTimeoutProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
      await sleepAsync(50.millis)

    let behindNATSwitch = SwitchStub.new(makeSwitch(), connectTimeoutProc)
    let publicSwitch = makeSwitch()
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
    ): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
      raise newException(DialFailedError, "error")

    let behindNATSwitch = SwitchStub.new(makeSwitch(), connectErrorProc)
    let publicSwitch = makeSwitch()
    ductrClientTest(behindNATSwitch, publicSwitch):
      try:
        let client = DcutrClient.new(connectTimeout = 5.millis)
        await client.startSync(
          behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
        )
      except DcutrError as err:
        check err.parent of AllFuturesFailedError

  proc ductrServerTest(connectStub: connectStubType) {.async.} =
    let behindNATSwitch = makeSwitch()
    let publicSwitch = SwitchStub.new(makeSwitch())

    let dcutrProto = Dcutr.new(publicSwitch, connectTimeout = 5.millis)
    publicSwitch.mount(dcutrProto)

    await allFutures(behindNATSwitch.start(), publicSwitch.start())
    defer:
      await allFutures(behindNATSwitch.stop(), publicSwitch.stop())

    await publicSwitch.connect(
      behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs
    )

    publicSwitch.connectStub = connectStub

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    expect AsyncTimeoutError:
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

  asyncTest "DCUtR server timeout when establishing a new connection":
    proc connectProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
      await sleepAsync(50.millis)

    await ductrServerTest(connectProc)

  asyncTest "DCUtR server error when establishing a new connection":
    proc connectProc(
        self: SwitchStub,
        peerId: PeerId,
        addrs: seq[MultiAddress],
        forceDial = false,
        reuseConnection = true,
        dir = Direction.Out,
    ): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
      raise newException(DialFailedError, "error")

    await ductrServerTest(connectProc)

  test "should return valid TCP and QUIC-v1 addresses only":
    let testAddrs = @[
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
      MultiAddress.init("/ip4/192.0.2.2/udp/3456/quic-v1").tryGet(),
      MultiAddress
        .init(
          "/ip4/203.0.113.6/udp/4567/quic-v1/p2p/QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N"
        )
        .tryGet(),
      MultiAddress
        .init(
          "/dns4/example.org/udp/5678/quic-v1/p2p/QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N"
        )
        .tryGet(),
      MultiAddress.init("/ip4/198.51.100.42/udp/7890").tryGet(),
      MultiAddress.init("/ip4/198.51.100.43/udp/7890/quic").tryGet(),
    ]

    let expected = @[
      MultiAddress.init("/ip4/192.0.2.1/tcp/1234").tryGet(),
      MultiAddress.init("/ip4/203.0.113.5/tcp/5678").tryGet(),
      MultiAddress.init("/ip6/::1/tcp/9012").tryGet(),
      MultiAddress.init("/dns4/example.com/tcp/3456").tryGet(),
      MultiAddress.init("/ip4/192.0.2.2/udp/3456/quic-v1").tryGet(),
      MultiAddress.init("/ip4/203.0.113.6/udp/4567/quic-v1").tryGet(),
      MultiAddress.init("/dns4/example.org/udp/5678/quic-v1").tryGet(),
    ]

    let res = getHolePunchableAddrs(testAddrs)

    check res == expected
