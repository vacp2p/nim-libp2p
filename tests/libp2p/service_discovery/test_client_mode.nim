# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import std/sets
import ../../../libp2p/protocols/kad_disco
import ../../../libp2p/protocols/kademlia_discovery/types
import
  ../../../libp2p/protocols/service_discovery/
    [discoverer, advertiser, serviceroutingtables]
import ../../tools/unittest
import ./utils

suite "Client mode":
  teardown:
    checkTrackers()

  test "client mode seeds main routing table from bootstrap peers":
    let bootstrapPeer = makePeerId()
    let bootstrapAddr = createTestMultiAddress("10.0.0.2")
    let switch = createSwitch()

    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = @[(bootstrapPeer, @[bootstrapAddr])],
      client = true,
      discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16),
    )

    check peersCount(disco.rtable) > 0

  test "client mode lookup creates interest table from bootstrap peers":
    let bootstrapPeer = makePeerId()
    let bootstrapAddr = createTestMultiAddress("10.0.0.3")
    let switch = createSwitch()
    let serviceId = makeServiceId()

    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = @[(bootstrapPeer, @[bootstrapAddr])],
      client = true,
      discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16),
    )

    check peersCount(disco.rtable) > 0
    check not disco.serviceRoutingTables.hasService(serviceId)

    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check disco.serviceRoutingTables.hasService(serviceId)

    let tableOpt = waitFor disco.serviceRoutingTables.getTable(serviceId)
    check tableOpt.isSome()
    let table = tableOpt.get()
    var inserted = 0
    for bucket in table.buckets:
      inserted += bucket.peers.len

    check inserted > 0

  test "client mode does not allow adding provided services":
    let switch = createSwitch()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = @[],
      client = true,
      discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16),
    )

    check not disco.serviceRoutingTables.hasService(serviceId)
    check len(disco.advertiser.running) == 0

    expect AssertionDefect:
      waitFor disco.addProvidedService(service)

    check not disco.serviceRoutingTables.hasService(serviceId)
    check len(disco.advertiser.running) == 0

  test "client mode does not allow removing provided services":
    let switch = createSwitch()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = @[],
      client = true,
      discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16),
    )

    expect AssertionDefect:
      waitFor disco.removeProvidedService(service)

    check not disco.serviceRoutingTables.hasService(serviceId)
    check len(disco.advertiser.running) == 0
