# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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
import ./helpers

suite "Dcutr":
  teardown:
    checkTrackers()

  asyncTest "Connect msg Encode / Decode":
    let addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let connectMsg = DcutrMsg(msgType: MsgType.Connect, addrs: addrs)

    let pb = connectMsg.encode()
    let connectMsgDecoded = DcutrMsg.decode(pb.buffer)

    check connectMsg == connectMsgDecoded

  asyncTest "Sync msg Encode / Decode":
    let addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
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

    await publicSwitch.connect(behindNATSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs)

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    for t in publicSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    try:
      # we can't hole punch when both peers are in the same machine. This means that the simultaneous dialings will result
      # in two connections attemps, instead of one. This dial is likely going to fail because the dcutr client is acting as the
      # tcp simultaneous incoming upgrader in the dialer which works only in the simultaneous open case.
      # The test should still pass if this doesn't fail though.
      await DcutrClient.new().startSync(behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs)
      .wait(300.millis)
    except CatchableError as exc:
      discard

    await sleepAsync(200.millis) # wait for the dcutr server to finish
    checkExpiring:
      # we still expect a new connection to be open by the other peer acting as the dcutr server
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 2

    await allFutures(behindNATSwitch.stop(), publicSwitch.stop())
