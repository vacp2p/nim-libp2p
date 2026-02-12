# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import strformat, sequtils
import ../../crypto/[secp, crypto]
import ../../[multiaddress, peerid]
import ./curve25519

type MixNodeInfo* = object
  peerId*: PeerId
  multiAddr*: MultiAddress
  mixPubKey*: FieldElement
  mixPrivKey*: FieldElement
  libp2pPubKey*: SkPublicKey
  libp2pPrivKey*: SkPrivateKey

proc initMixNodeInfo*(
    peerId: PeerId,
    multiAddr: MultiAddress,
    mixPubKey, mixPrivKey: FieldElement,
    libp2pPubKey: SkPublicKey,
    libp2pPrivKey: SkPrivateKey,
): MixNodeInfo =
  MixNodeInfo(
    peerId: peerId,
    multiAddr: multiAddr,
    mixPubKey: mixPubKey,
    mixPrivKey: mixPrivKey,
    libp2pPubKey: libp2pPubKey,
    libp2pPrivKey: libp2pPrivKey,
  )

proc generateRandom*(T: typedesc[MixNodeInfo], port: int): MixNodeInfo =
  let
    (mixPrivKey, mixPubKey) = generateKeyPair().expect("Generate key pair error")
    keyPair = SkKeyPair.random(newRng()[])
    pubKeyProto = PublicKey(scheme: Secp256k1, skkey: keyPair.pubkey)

  MixNodeInfo(
    peerId: PeerId.init(pubKeyProto).expect("PeerId init error"),
    multiAddr: MultiAddress.init(fmt"/ip4/0.0.0.0/tcp/{port}").tryGet(),
    mixPubKey: mixPubKey,
    mixPrivKey: mixPrivKey,
    libp2pPubKey: keyPair.pubkey,
    libp2pPrivKey: keyPair.seckey,
  )

proc generateRandomMany*(
    T: typedesc[MixNodeInfo], count: int, basePort: int = 4242
): seq[MixNodeInfo] =
  var nodeInfos = newSeq[MixNodeInfo](count)
  for i in 0 ..< count:
    nodeInfos[i] = MixNodeInfo.generateRandom(basePort + i)
  nodeInfos

type MixPubInfo* = object
  peerId*: PeerId
  multiAddr*: MultiAddress
  mixPubKey*: FieldElement
  libp2pPubKey*: SkPublicKey

proc init*(
    T: typedesc[MixPubInfo],
    peerId: PeerId,
    multiAddr: MultiAddress,
    mixPubKey: FieldElement,
    libp2pPubKey: SkPublicKey,
): T =
  T(
    peerId: peerId,
    multiAddr: multiAddr,
    mixPubKey: mixPubKey,
    libp2pPubKey: libp2pPubKey,
  )

proc get*(info: MixPubInfo): (PeerId, MultiAddress, FieldElement, SkPublicKey) =
  (info.peerId, info.multiAddr, info.mixPubKey, info.libp2pPubKey)

proc toMixPubInfo*(info: MixNodeInfo): MixPubInfo =
  MixPubInfo.init(info.peerId, info.multiAddr, info.mixPubKey, info.libp2pPubKey)

proc includeAllExcept*(
    allNodes: seq[MixNodeInfo], exceptNode: MixNodeInfo
): seq[MixPubInfo] =
  allNodes.mapIt(it.toMixPubInfo()).filterIt(it.peerId != exceptNode.peerId)
