# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, std/[enumerate, tables]
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

import ../../tools/[unittest, crypto]
import ./[mock_mix, spam_protection_impl]

proc createSwitch(
    multiAddr: MultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1, skkey: libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupSwitches*(numNodes: int): seq[Switch] =
  let mixNodes = initializeMixNodes(numNodes).expect("could not initialize nodes")
  var switches: seq[Switch] = @[]
  for index, mixNode in enumerate(mixNodes):
    let pubInfo =
      mixNodes.getMixPubInfoByIndex(index).expect("could not obtain pub info")

    pubInfo.writeToFile(index).expect("could not write pub info")
    mixNode.writeToFile(index).expect("could not write mix info")

    let switch = createSwitch(mixNode.multiAddr, Opt.some(mixNode.libp2pPrivKey))
    switches.add(switch)

  return switches

proc setupMixNode(
    index, numNodes: int,
    switch: Switch,
    destReadBehavior: Opt[tuple[codec: string, callback: DestReadBehavior]],
    spamProtectionRateLimit: Opt[int],
): MixProtocol =
  let spamProtection =
    if spamProtectionRateLimit.isSome():
      Opt.some(
        SpamProtection(newRateLimitSpamProtection(spamProtectionRateLimit.get()))
      )
    else:
      Opt.none(SpamProtection)

  let proto = MixProtocol
    .new(index, numNodes, switch, spamProtection = spamProtection)
    .expect("should have initialized mix protocol")

  if destReadBehavior.isSome():
    let (codec, callback) = destReadBehavior.get()
    proto.registerDestReadBehavior(codec, callback)

  switch.mount(proto)
  proto

proc setupMixNodes*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
    spamProtectionRateLimit = Opt.none(int),
): Future[seq[MixProtocol]] {.async.} =
  let switches = setupSwitches(numNodes)
  var nodes: seq[MixProtocol] = @[]
  for index, _ in enumerate(switches):
    nodes.add(
      setupMixNode(
        index, numNodes, switches[index], destReadBehavior, spamProtectionRateLimit
      )
    )
  nodes

proc setupMixNodesWithMock*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
): Future[tuple[nodes: seq[MixProtocol], mock: MockMixProtocol]] {.async.} =
  ## Like setupMixNodes, but the first node is a MockMixProtocol.
  let switches = setupSwitches(numNodes)
  var nodes: seq[MixProtocol] = @[]

  let info = MixNodeInfo.readFromFile(0).expect("could not read mix node info")
  let mock = MockMixProtocol.new(info, switches[0])

  for i in 1 ..< numNodes:
    mock.nodePool.add(MixPubInfo.readFromFile(i).expect("could not read pub info"))

  if destReadBehavior.isSome():
    let (codec, cb) = destReadBehavior.get()
    mock.registerDestReadBehavior(codec, cb)

  switches[0].mount(MixProtocol(mock))
  nodes.add(MixProtocol(mock))

  for index in 1 ..< numNodes:
    nodes.add(
      setupMixNode(index, numNodes, switches[index], destReadBehavior, Opt.none(int))
    )

  (nodes, mock)

proc setupDestNode*[T: LPProtocol](
    proto: T
): Future[tuple[switch: Switch, proto: T]] {.async.} =
  let switch = createSwitch()
  switch.mount(proto)
  await switch.start()
  return (switch, proto)

proc stopDestNode*(switch: Switch) {.async.} =
  await switch.stop()
