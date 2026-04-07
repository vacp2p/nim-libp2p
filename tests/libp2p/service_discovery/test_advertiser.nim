# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[sets]
import chronos
import ../../../libp2p/[extended_peer_record, peerid]
import ../../../libp2p/protocols/kad_disco
import ../../../libp2p/protocols/kademlia_discovery/types
import ../../../libp2p/protocols/service_discovery/[advertiser, serviceroutingtables]
import ../../tools/unittest
import ../kademlia/utils
import ./utils

# ===========================================================================
# Service management
# ===========================================================================

suite "Advertiser - addProvidedService":
  teardown:
    checkTrackers()

  asyncTest "creates routing table entry for the service":
    let disco = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    await disco.addProvidedService(service)

    check disco.serviceRoutingTables.hasService(serviceId)

  asyncTest "with empty routing table: creates table but schedules no actions":
    # Source skips scheduling when bucket.peers.len() == 0
    let disco = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    await disco.addProvidedService(service) # no peers in routing table

    check disco.serviceRoutingTables.hasService(serviceId)

  asyncTest "schedules up to kRegister actions per populated bucket":
    let disco = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    # populateAdvTable creates service as Interest with peers only in bucket[0]
    # (empty main routing table so no peers spread across other buckets)
    await disco.populateAdvTable(serviceId)

    await disco.addProvidedService(service)

    # bucket[0] has kRegister+2 peers; we should schedule exactly kRegister tasks
    check disco.advertiser.running.len() == disco.discoConf.kRegister

  asyncTest "adding same service twice is idempotent":
    let disco = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    await disco.addProvidedService(service)
    let queueLenAfterFirst = disco.advertiser.running.len()

    await disco.addProvidedService(service)

    # Routing table still exists exactly once
    check disco.serviceRoutingTables.hasService(serviceId)
    # Queue should not grow — second call is a no-op for the routing table
    check disco.advertiser.running.len() == queueLenAfterFirst

  asyncTest "multiple distinct services each get their own routing table":
    let disco = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let s3 = makeServiceInfo("svc-3")

    disco.populateRoutingTable(1)
    await disco.addProvidedService(s1)
    await disco.addProvidedService(s2)
    await disco.addProvidedService(s3)

    check disco.serviceRoutingTables.hasService(s1.id.hashServiceId())
    check disco.serviceRoutingTables.hasService(s2.id.hashServiceId())
    check disco.serviceRoutingTables.hasService(s3.id.hashServiceId())

suite "Advertiser - removeProvidedService":
  teardown:
    checkTrackers()

  asyncTest "removes routing table and clears its pending actions":
    let disco = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let sid1 = s1.id.hashServiceId()
    let sid2 = s2.id.hashServiceId()
    disco.populateRoutingTable(1)
    await disco.addProvidedService(s1)
    await disco.addProvidedService(s2)

    await disco.removeProvidedService(s1)

    check:
      not disco.serviceRoutingTables.hasService(sid1)
      disco.serviceRoutingTables.hasService(sid2)
      disco.advertiser.running.len() == 1

  asyncTest "removing non-existent service is a no-op":
    let disco = createMockDiscovery()
    let service = makeServiceInfo()

    await disco.removeProvidedService(service) # must not crash or error
    check not disco.serviceRoutingTables.hasService(service.id.hashServiceId())

  asyncTest "removing one service leaves others intact":
    let disco = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    disco.populateRoutingTable(1)
    await disco.addProvidedService(s1)
    await disco.addProvidedService(s2)

    await disco.removeProvidedService(s1)

    check not disco.serviceRoutingTables.hasService(s1.id.hashServiceId())
    check disco.serviceRoutingTables.hasService(s2.id.hashServiceId())
