# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash]
import ./kademlia
import ./kademlia_discovery/[randomfind, types]

export randomfind, types

logScope:
  topics = "kad-disco"

proc refreshSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  let peerInfo = disco.switch.peerInfo
  let peerRecord = PeerRecord.init(peerInfo.peerId, peerInfo.addrs)
  let privKey = disco.switch.peerInfo.privateKey

  let signedRecord = SignedPeerRecord.init(privKey, peerRecord).valueOr:
    error "Failed to sign peer record", error
    return

  let encodedSR = signedRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = peerInfo.peerId.toKey()

  let putRes = await disco.putValue(key, encodedSR)
  if putRes.isErr:
    error "Failed to put signed peer record", err = putRes.error

proc maintainSelfSignedPeerRecord(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh self signed peer record", disco.config.bucketRefreshTime:
    await disco.refreshSelfSignedPeerRecord()

method start*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  if disco.started:
    warn "Starting kad-disco twice"
    return

  disco.selfSignedLoop = disco.maintainSelfSignedPeerRecord()
  disco.maintenanceLoop = disco.maintainBuckets()
  disco.republishLoop = disco.manageRepublishProvidedKeys()
  disco.expiredLoop = disco.manageExpiredProviders()

  disco.started = true

  info "Kademlia Discovery started"

method stop*(disco: KademliaDiscovery) {.async: (raises: []).} =
  if not disco.started:
    return

  disco.started = false

  disco.selfSignedLoop.cancelSoon()
  disco.selfSignedLoop = nil

  disco.maintenanceLoop.cancelSoon()
  disco.maintenanceLoop = nil

  disco.republishLoop.cancelSoon()
  disco.republishLoop = nil

  disco.expiredLoop.cancelSoon()
  disco.expiredLoop = nil
