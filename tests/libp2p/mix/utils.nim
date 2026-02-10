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

proc setupMixNode[T: MixProtocol](
    index, numNodes: int,
    switch: Switch,
    destReadBehavior: Opt[tuple[codec: string, callback: DestReadBehavior]],
    spamProtectionRateLimit: Opt[int],
): T =
  let spamProtection =
    if spamProtectionRateLimit.isSome():
      Opt.some(
        SpamProtection(newRateLimitSpamProtection(spamProtectionRateLimit.get()))
      )
    else:
      Opt.none(SpamProtection)

  let proto = T.new(index, numNodes, switch, spamProtection = spamProtection)

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
      setupMixNode[MixProtocol](
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

  let mock = setupMixNode[MockMixProtocol](
    0, numNodes, switches[0], destReadBehavior, Opt.none(int)
  )
  nodes.add(mock)

  for index in 1 ..< numNodes:
    nodes.add(
      setupMixNode[MixProtocol](
        index, numNodes, switches[index], destReadBehavior, Opt.none(int)
      )
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

###

const NoReplyProtocolCodec* = "/test/1.0.0"

type NoReplyProtocol* = ref object of LPProtocol
  receivedMessages*: AsyncQueue[seq[byte]]

proc new*(T: typedesc[NoReplyProtocol]): NoReplyProtocol =
  let nrProto = NoReplyProtocol()
  nrProto.receivedMessages = newAsyncQueue[seq[byte]]()

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      let buffer = await conn.readLp(1024)
      await nrProto.receivedMessages.put(buffer)
    except LPStreamError:
      raiseAssert "shuld not happen"
    await conn.close()

  nrProto.handler = handler
  nrProto.codec = NoReplyProtocolCodec
  nrProto
