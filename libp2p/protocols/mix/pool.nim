# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Mix Node Pool Management
##
## This module provides an abstraction layer for managing mix node information.
## It encapsulates access to the peerStore's MixPubKeyBook, AddressBook, and KeyBook,
## providing a clean interface for the mix protocol to interact with mix node data.

import std/[options, sequtils, tables]
import results
import ../../peerstore
import ../../peerid
import ../../multiaddress
import ../../multicodec
import ../../crypto/crypto
import ../../crypto/curve25519
import ./mix_node

export mix_node.MixPubInfo

const
  # Mix protocol only supports IPv4 with TCP or QUIC-v1
  TCP_IP4 = mapAnd(IP4, mapEq("tcp"))
  UDP_IP4 = mapAnd(IP4, mapEq("udp"))
  QUIC_V1_IP4 = mapAnd(UDP_IP4, mapEq("quic-v1"))

func getSupportedMultiaddr(maddrs: seq[MultiAddress]): Option[MultiAddress] =
  ## Returns the first multiaddress that is supported by the mix protocol.
  ## Mix protocol currently only supports IPv4 addresses with TCP or QUIC-v1 transports.
  for multiaddr in maddrs:
    if TCP_IP4.match(multiaddr) or QUIC_V1_IP4.match(multiaddr):
      return some(multiaddr)
  return none(MultiAddress)

type MixNodePool* = ref object
  ## Manages mix node public information through the peerStore.
  ## This abstraction allows the mix protocol to interact with mix node data
  ## without directly coupling to peerStore implementation details.
  ##
  ## Future enhancements:
  ## - Peer scoring: Track node reliability, latency, and performance metrics
  ## - Pool maintenance: Automatic pruning of stale/unresponsive nodes
  peerStore: PeerStore

proc new*(T: typedesc[MixNodePool], peerStore: PeerStore): T =
  ## Create a new MixNodePool instance backed by the given peerStore.
  T(peerStore: peerStore)

proc add*(pool: MixNodePool, info: MixPubInfo) =
  ## Add a mix node to the pool.
  ## MixPubKeyBook entry is always updated.
  ## Address is added to AddressBook if not already present.
  ## KeyBook is only set if not already present (to avoid overwriting
  ## keys set by the Identify protocol).
  pool.peerStore[MixPubKeyBook][info.peerId] = info.mixPubKey

  # Add address if not already present
  let existingAddrs = pool.peerStore[AddressBook][info.peerId]
  if info.multiAddr notin existingAddrs:
    pool.peerStore[AddressBook][info.peerId] = existingAddrs & @[info.multiAddr]

  # Only set key if peer has no key yet
  let existingKey = pool.peerStore[KeyBook][info.peerId]
  if existingKey.scheme != Secp256k1:
    pool.peerStore[KeyBook][info.peerId] =
      PublicKey(scheme: Secp256k1, skkey: info.libp2pPubKey)

proc remove*(pool: MixNodePool, peerId: PeerId): bool =
  ## Remove a mix node from the pool. Returns true if the node was present.
  pool.peerStore[MixPubKeyBook].del(peerId)
  # Note: We only delete from MixPubKeyBook. The peer may still have
  # entries in AddressBook/KeyBook for other protocols.

proc get*(pool: MixNodePool, peerId: PeerId): Opt[MixPubInfo] =
  ## Get MixPubInfo for a peer. Returns none if peer is not in the pool
  ## or if required information (address, key) is missing.
  let mixPubKey = pool.peerStore[MixPubKeyBook][peerId]
  if mixPubKey == default(Curve25519Key):
    return Opt.none(MixPubInfo)

  let addrs = pool.peerStore[AddressBook][peerId]
  # Mix protocol only supports IPv4 addresses with TCP or QUIC-v1 transports
  let ipv4Addr = getSupportedMultiaddr(addrs).valueOr:
    return Opt.none(MixPubInfo)

  let pubKey = pool.peerStore[KeyBook][peerId]
  if pubKey.scheme != Secp256k1:
    return Opt.none(MixPubInfo)

  Opt.some(MixPubInfo.init(peerId, ipv4Addr, mixPubKey, pubKey.skkey))

proc peerIds*(pool: MixNodePool): seq[PeerId] =
  ## Get all peer IDs in the mix node pool.
  pool.peerStore[MixPubKeyBook].book.keys.toSeq()

proc len*(pool: MixNodePool): int =
  ## Get the number of mix nodes in the pool.
  pool.peerStore[MixPubKeyBook].len
