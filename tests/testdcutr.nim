# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos, metrics
import unittest2
import ../libp2p/protocols/connectivity/dcutr/[dcutr, messages]
import ../libp2p/builders
import ./helpers

suite "Dcutr":
  teardown:
    checkTrackers()

  asyncTest "Encode / Decode":
    let addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let connectMsg = DcutrMsg(msgType: MsgType.Connect, addrs: addrs)

    let pb = connectMsg.encode()
    let connectMsgDecoded = DcutrMsg.decode(pb.buffer)

    check connectMsg == connectMsgDecoded

  asyncTest "Direct connection":
    let clientSwitch = newStandardSwitch()

    let serverSwitch = newStandardSwitch()
    let dcutrProto = Dcutr.new(serverSwitch)
    serverSwitch.mount(dcutrProto)

    asyncSpawn serverSwitch.start()

    let conn = await clientSwitch.dial(serverSwitch.peerInfo.peerId, serverSwitch.peerInfo.addrs, @[DcutrCodec])
    let directConn = await Dcutr.new(clientSwitch).startSync(conn)
    echo await directConn.readLp(1024)

    await allFutures(serverSwitch.stop())