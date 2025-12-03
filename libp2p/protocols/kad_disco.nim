# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results, options
import ../utils/heartbeat
import ../[peerid, switch, multihash, peerinfo]
import ./kademlia
import ./kademlia_discovery/[randomfind, types]

export randomfind, types

logScope:
  topics = "kad-disco"

proc refreshSelfSignedPeerRecord*(
    disco: KademliaDiscovery, prOpt: Option[LogosPeerRecord]
) {.async: (raises: [CancelledError]).} =
  let logosPeerRecord = prOpt.valueOr:
    await disco.switch.peerInfo.update()

    LogosPeerRecord.init(disco.switch.peerInfo)

  let encodedSR = logosPeerRecord.encode().valueOr:
    error "Failed to encode signed peer record", error
    return

  let key = disco.switch.peerInfo.peerId.toKey()

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
