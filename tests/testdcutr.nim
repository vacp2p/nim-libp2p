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
import ../libp2p/protocols/connectivity/relay/[relay, client]
import ../libp2p/services/autorelayservice
import ../libp2p/protocols/connectivity/dcutr/[core, client, server]
from ../libp2p/protocols/connectivity/autonat/core import NetworkReachability
import ../libp2p/builders
import ./helpers

proc createSwitch(r: Relay = nil, autoRelay: Service = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()

  if autoRelay != nil:
    builder = builder.withServices(@[autoRelay])

  if r != nil:
    builder = builder.withCircuitRelay(r)

  return builder.build()

proc buildRelayMA(switchRelay: Switch, switchClient: Switch): MultiAddress =
  MultiAddress.init($switchRelay.peerInfo.addrs[0] & "/p2p/" &
                    $switchRelay.peerInfo.peerId & "/p2p-circuit/p2p/" &
                    $switchClient.peerInfo.peerId).get()

suite "Dcutr":
  teardown:
    checkTrackers()

  asyncTest "Connect msg Encode / Decode":
    let addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let connectMsg = DcutrMsg(msgType: MsgType.Connect, addrs: addrs)

    let pb = connectMsg.encode()
    let connectMsgDecoded = DcutrMsg.decode(pb.buffer)

    check connectMsg == connectMsgDecoded
    echo connectMsgDecoded

  asyncTest "Sync msg Encode / Decode":
    let addrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let syncMsg = DcutrMsg(msgType: MsgType.Sync, addrs: addrs)

    let pb = syncMsg.encode()
    let syncMsgDecoded = DcutrMsg.decode(pb.buffer)

    check syncMsg == syncMsgDecoded

  asyncTest "Direct connection":

    let fut = newFuture[seq[MultiAddress]]()

    let switch2 = createSwitch(RelayClient.new())
    proc checkMA(address: seq[MultiAddress]) =
      if not fut.completed():
        echo $address
        fut.complete(address)

    let relayClient = RelayClient.new()
    let autoRelayService = AutoRelayService.new(1, relayClient, checkMA, newRng())
    let behindNATSwitch = createSwitch(relayClient, autoRelayService)

    let switchRelay = createSwitch(Relay.new())
    let publicSwitch = createSwitch(RelayClient.new())

    let dcutrProto = Dcutr.new(publicSwitch)
    publicSwitch.mount(dcutrProto)

    await allFutures(switchRelay.start(), behindNATSwitch.start(), publicSwitch.start())

    await behindNATSwitch.connect(switchRelay.peerInfo.peerId, switchRelay.peerInfo.addrs)
    await publicSwitch.connect(behindNATSwitch.peerInfo.peerId, (await fut))

    for t in behindNATSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    for t in publicSwitch.transports:
      t.networkReachability = NetworkReachability.NotReachable

    await DcutrClient.new().startSync(behindNATSwitch, publicSwitch.peerInfo.peerId, behindNATSwitch.peerInfo.addrs)

    echo behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId)
    checkExpiring:
      behindNATSwitch.connManager.connCount(publicSwitch.peerInfo.peerId) == 1

    await allFutures(switchRelay.stop(), behindNATSwitch.stop(), publicSwitch.stop())