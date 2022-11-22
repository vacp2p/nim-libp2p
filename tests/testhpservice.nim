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
import ./helpers
import ../libp2p/[builders,
                  switch,
                  services/hpservice]

proc createAutonatSwitch(): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()
    .build()

suite "Hope Punching":
  teardown:
    checkTrackers()
  asyncTest "Hope Punching Private Reachability test":
    let switch1 = createAutonatSwitch()
    let switch2 = createAutonatSwitch()
    let switch3 = createAutonatSwitch()
    let switch4 = createAutonatSwitch()

    let hpservice = HPService.new()
    check hpservice.networkReachability() == NetworkReachability.Unknown
    switch1.addService(hpservice)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    echo $switch1.peerInfo.listenAddrs
    switch1.peerInfo.listenAddrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/1").tryGet()]
    await switch1.peerInfo.update()
    echo $switch1.peerInfo.listenAddrs

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    check hpservice.networkReachability() == NetworkReachability.Private

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  asyncTest "Hope Punching Public Reachability test":
    let switch1 = createAutonatSwitch()
    let switch2 = createAutonatSwitch()
    let switch3 = createAutonatSwitch()
    let switch4 = createAutonatSwitch()

    let hpservice = HPService.new()
    check hpservice.networkReachability() == NetworkReachability.Unknown
    switch1.addService(hpservice)

    await switch1.start()
    await switch2.start()
    await switch3.start()
    await switch4.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
    await switch1.connect(switch3.peerInfo.peerId, switch3.peerInfo.addrs)
    await switch1.connect(switch4.peerInfo.peerId, switch4.peerInfo.addrs)

    check hpservice.networkReachability() == NetworkReachability.Public

    await allFuturesThrowing(
      switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

  # asyncTest "IPFS Hope Punching test":
  #   let switch1 = createAutonatSwitch()

  #   switch1.addService(HPService.new())

  #   await switch1.start()

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN").get(),
  #     @[MultiAddress.init("/ip4/139.178.91.71/tcp/4001").get()]
  #   )

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt").get(),
  #     @[MultiAddress.init("/ip4/145.40.118.135/tcp/4001").get()]
  #   )

  #   asyncSpawn switch1.connect(
  #     PeerId.init("QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ").get(),
  #     @[MultiAddress.init("/ip4/104.131.131.82/tcp/4001").get()]
  #   )

  #   await sleepAsync(20.seconds)

  #   await allFuturesThrowing(
  #     switch1.stop())