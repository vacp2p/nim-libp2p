# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, strformat, sequtils
import
  ../../../libp2p/[
    protocols/mix,
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

proc generateMixNodeInfo*(port: int): MixNodeInfo =
  let (mixPrivKey, mixPubKey) = generateKeyPair().expect("Generate key pair error")
  let
    rng = newRng()
    keyPair = SkKeyPair.random(rng[])
    pubKeyProto = PublicKey(scheme: Secp256k1, skkey: keyPair.pubkey)
    peerId = PeerId.init(pubKeyProto).expect("PeerId init error")
    multiAddr = MultiAddress.init(fmt"/ip4/0.0.0.0/tcp/{port}").tryGet()

  MixNodeInfo(
    peerId: peerId,
    multiAddr: multiAddr,
    mixPubKey: mixPubKey,
    mixPrivKey: mixPrivKey,
    libp2pPubKey: keyPair.pubkey,
    libp2pPrivKey: keyPair.seckey,
  )

proc generateMixNodeInfos*(count: int, basePort: int = 4242): seq[MixNodeInfo] =
  var nodeInfos = newSeq[MixNodeInfo](count)
  for i in 0 ..< count:
    nodeInfos[i] = generateMixNodeInfo(basePort + i)
  nodeInfos

proc createSwitch(
    multiAddr: MultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1, skkey: libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupMixNode[T: MixProtocol](
    mixNodeInfo: MixNodeInfo,
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

  if destReadBehavior.isSome():
    let (codec, callback) = destReadBehavior.get()
    proto.registerDestReadBehavior(codec, callback)

  switch.mount(proto)
  proto

proc populateNodePool*(nodes: seq[MixProtocol], nodeInfos: seq[MixNodeInfo]) =
  for i in 0 ..< nodes.len:
    let pubInfos = nodeInfos
      .filterIt(it.peerId != nodes[i].switch.peerInfo.peerId)
      .mapIt(it.toMixPubInfo())
    nodes[i].nodePool.add(pubInfos)

proc setupMixNodes*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
    spamProtectionRateLimit = Opt.none(int),
): Future[seq[MixProtocol]] {.async.} =
  let basePort = 4242
  var nodes: seq[MixProtocol] = @[]
  var nodeInfos: seq[MixNodeInfo] = @[]
  for index in 0 ..< numNodes:
    let mixNodeInfo = generateMixNodeInfo(basePort + index)
    nodeInfos.add(mixNodeInfo)
    let switch =
      createSwitch(mixNodeInfo.multiAddr, Opt.some(mixNodeInfo.libp2pPrivKey))

    nodes.add(
      setupMixNode[MixProtocol](
        mixNodeInfo, switch, destReadBehavior, spamProtectionRateLimit
      )
    )

  populateNodePool(nodes, nodeInfos)

  nodes

proc setupMixNodesWithMock*(
    numNodes: int,
    destReadBehavior = Opt.none(tuple[codec: string, callback: DestReadBehavior]),
): Future[tuple[nodes: seq[MixProtocol], mock: MockMixProtocol]] {.async.} =
  ## Like setupMixNodes, but the first node is a MockMixProtocol.
  var nodes: seq[MixProtocol] = @[]
  var nodeInfos: seq[MixNodeInfo] = @[]

  let basePort = 4242
  let mockMixNodeInfo = generateMixNodeInfo(basePort)
  nodeInfos.add(mockMixNodeInfo)
  let mockSwitch =
    createSwitch(mockMixNodeInfo.multiAddr, Opt.some(mockMixNodeInfo.libp2pPrivKey))

  let mock = setupMixNode[MockMixProtocol](
    mockMixNodeInfo, mockSwitch, destReadBehavior, Opt.none(int)
  )
  nodes.add(mock)

  for index in 1 ..< numNodes:
    let mixNodeInfo = generateMixNodeInfo(basePort + index)
    nodeInfos.add(mixNodeInfo)
    let switch =
      createSwitch(mixNodeInfo.multiAddr, Opt.some(mixNodeInfo.libp2pPrivKey))
    nodes.add(
      setupMixNode[MixProtocol](mixNodeInfo, switch, destReadBehavior, Opt.none(int))
    )

  populateNodePool(nodes, nodeInfos)

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
