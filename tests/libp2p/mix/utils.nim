# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, std/[enumerate, sequtils, tables], stew/byteutils
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

import ../../tools/[unittest, crypto]
import ./spam_protection_impl

proc createSwitch*(
    multiAddr: MultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1, skkey: libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupSwitches*(numNodes: int): seq[Switch] =
  # Initialize mix nodes
  let mixNodes = initializeMixNodes(numNodes).expect("could not initialize nodes")
  var nodes: seq[Switch] = @[]
  for index, mixNode in enumerate(mixNodes):
    let pubInfo =
      mixNodes.getMixPubInfoByIndex(index).expect("could not obtain pub info")

    pubInfo.writeToFile(index).expect("could not write pub info")
    mixNode.writeToFile(index).expect("could not write mix info")

    let switch = createSwitch(mixNode.multiAddr, Opt.some(mixNode.libp2pPrivKey))
    nodes.add(switch)

  return nodes

proc setupMixNodes*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
    spamProtectionRateLimit = Opt.none(int),
): Future[seq[MixProtocol]] {.async.} =
  var nodes: seq[MixProtocol] = @[]
  let switches = setupSwitches(numNodes)

  for index, _ in enumerate(switches):
    let spamProtection =
      if spamProtectionRateLimit.isSome():
        Opt.some(
          SpamProtection(newRateLimitSpamProtection(spamProtectionRateLimit.get()))
        )
      else:
        Opt.none(SpamProtection)

    let proto = MixProtocol
      .new(index, switches.len, switches[index], spamProtection = spamProtection)
      .expect("should have initialized mix protocol")

    if destReadBehavior.isSome():
      let (codec, callback) = destReadBehavior.get()
      proto.registerDestReadBehavior(codec, callback)

    nodes.add(proto)
    switches[index].mount(proto)
  nodes

proc startNodes*(nodes: seq[MixProtocol]) {.async.} =
  await nodes.mapIt(it.switch.start()).allFutures()

proc stopNodes*(nodes: seq[MixProtocol]) {.async.} =
  await nodes.mapIt(it.switch.stop()).allFutures()

template startNodesAndDeferStop*(nodes: seq[MixProtocol]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

proc setupDestNode*[T: LPProtocol](
    proto: T
): Future[tuple[switch: Switch, proto: T]] {.async.} =
  let switch = createSwitch()
  switch.mount(proto)
  await switch.start()
  return (switch, proto)

proc stopDestNode*(switch: Switch) {.async.} =
  await switch.stop()
