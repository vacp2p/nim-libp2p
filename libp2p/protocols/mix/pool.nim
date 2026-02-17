# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Mix Node Pool Management
##
## This module provides an abstraction layer for managing mix node information.
## It encapsulates access to the peerStore's MixPubKeyBook, AddressBook, and KeyBook,
## providing a clean interface for the mix protocol to interact with mix node data.

import std/[sequtils, tables]
import results
import ../../peerstore
import ../../peerid
import ../../multiaddress
import ../../crypto/crypto
import ../../crypto/curve25519
import ./mix_node
import ./multiaddr as mix_multiaddr

export mix_node.MixPubInfo

func isSupportedMultiaddr(maddr: MultiAddress): bool =
  ## Returns true if the multiaddress is supported by the mix protocol.
  ## Mix protocol supports IPv4 addresses with TCP or QUIC-v1 transports,
  ## including circuit-relay addresses that use these transports.
  let baseAddr = mix_multiaddr.getBaseTransport(maddr).valueOr:
    return false
  TCP_IP4.match(baseAddr) or QUIC_V1_IP4.match(baseAddr)

func findSupportedMultiaddr(maddrs: seq[MultiAddress]): Opt[MultiAddress] =
  ## Returns the first multiaddress that is supported by the mix protocol.
  for maddr in maddrs:
    if isSupportedMultiaddr(maddr):
      return Opt.some(maddr)
  Opt.none(MultiAddress)

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

proc add*(pool: MixNodePool, infos: seq[MixPubInfo]) =
  ## Add multiple mix nodes to the pool.
  for info in infos:
    pool.add(info)

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

  # Get the address - prefer LastSeenOutboundBook, fall back to AddressBook
  # Mix protocol only supports IPv4 addresses with TCP or QUIC-v1 transports
  var supportedAddr: MultiAddress
  let lastSeenAddr = pool.peerStore[LastSeenOutboundBook][peerId]
  if lastSeenAddr.isSome and isSupportedMultiaddr(lastSeenAddr.get):
    supportedAddr = lastSeenAddr.get
  else:
    supportedAddr = findSupportedMultiaddr(pool.peerStore[AddressBook][peerId]).valueOr:
      return Opt.none(MixPubInfo)

  let pubKey = pool.peerStore[KeyBook][peerId]
  if pubKey.scheme != Secp256k1:
    return Opt.none(MixPubInfo)

  Opt.some(MixPubInfo.init(peerId, supportedAddr, mixPubKey, pubKey.skkey))

proc peerIds*(pool: MixNodePool): seq[PeerId] =
  ## Get all peer IDs in the mix node pool.
  pool.peerStore[MixPubKeyBook].book.keys.toSeq()

proc len*(pool: MixNodePool): int =
  ## Get the number of mix nodes in the pool.
  pool.peerStore[MixPubKeyBook].len
