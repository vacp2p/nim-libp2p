# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, std/strformat
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/curve25519,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/crypto,
    crypto/secp,
  ]

import ../../tools/[unittest, crypto]
import ./[mock_mix, spam_protection_impl]

proc generateMixNodes*(count: int, basePort: int = 4242): seq[MixNodeInfo] =
  var nodes = newSeq[MixNodeInfo](count)
  for i in 0 ..< count:
    let (mixPrivKey, mixPubKey) = generateKeyPair().expect("Generate key pair error")
    let
      rng = newRng()
      keyPair = SkKeyPair.random(rng[])
      pubKeyProto = PublicKey(scheme: Secp256k1, skkey: keyPair.pubkey)
      peerId = PeerId.init(pubKeyProto).expect("PeerId init error")
      multiAddr = MultiAddress.init(fmt"/ip4/0.0.0.0/tcp/{basePort + i}").tryGet()

    nodes[i] = MixNodeInfo(
      peerId: peerId,
      multiAddr: multiAddr,
      mixPubKey: mixPubKey,
      mixPrivKey: mixPrivKey,
      libp2pPubKey: keyPair.pubkey,
      libp2pPrivKey: keyPair.seckey,
    )
  nodes

proc initializeMixNodes*(count: int, basePort: int = 4242): seq[MixNodeInfo] =
  ## Creates and initializes a set of mix nodes in memory.
  generateMixNodes(count, basePort)

proc toMixPubInfo*(node: MixNodeInfo): MixPubInfo =
  MixPubInfo.init(node.peerId, node.multiAddr, node.mixPubKey, node.libp2pPubKey)

proc createSwitch(
    multiAddr: MultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1, skkey: libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupSwitches(mixNodes: seq[MixNodeInfo]): seq[Switch] =
  var switches: seq[Switch] = @[]
  for mixNode in mixNodes:
    let switch = createSwitch(mixNode.multiAddr, Opt.some(mixNode.libp2pPrivKey))
    switches.add(switch)
  switches

proc setupMixNode[T: MixProtocol](
    mixNodeInfo: MixNodeInfo,
    allNodes: seq[MixNodeInfo],
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

  let proto = T.new(mixNodeInfo, switch, spamProtection = spamProtection)

  for node in allNodes:
    if node.peerId != mixNodeInfo.peerId:
      proto.nodePool.add(node.toMixPubInfo())

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
  let mixNodes = initializeMixNodes(numNodes)
  let switches = setupSwitches(mixNodes)
  var nodes: seq[MixProtocol] = @[]
  for index in 0 ..< numNodes:
    nodes.add(
      setupMixNode[MixProtocol](
        mixNodes[index], mixNodes, switches[index], destReadBehavior,
        spamProtectionRateLimit,
      )
    )
  nodes

proc setupMixNodesWithMock*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
): Future[tuple[nodes: seq[MixProtocol], mock: MockMixProtocol]] {.async.} =
  ## Like setupMixNodes, but the first node is a MockMixProtocol.
  let mixNodes = initializeMixNodes(numNodes)
  let switches = setupSwitches(mixNodes)
  var nodes: seq[MixProtocol] = @[]

  let mock = setupMixNode[MockMixProtocol](
    mixNodes[0], mixNodes, switches[0], destReadBehavior, Opt.none(int)
  )
  nodes.add(mock)

  for index in 1 ..< numNodes:
    nodes.add(
      setupMixNode[MixProtocol](
        mixNodes[index], mixNodes, switches[index], destReadBehavior, Opt.none(int)
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
      raiseAssert "should not happen"
    finally:
      await conn.close()

  nrProto.handler = handler
  nrProto.codec = NoReplyProtocolCodec
  nrProto
