# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import ../../crypto/secp
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
