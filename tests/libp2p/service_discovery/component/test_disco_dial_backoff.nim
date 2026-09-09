# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/strutils
import chronos, results
import
  ../../../../libp2p/[
    peerstore,
    protocols/kademlia,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/connection,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../tools/[lifecycle, multiaddress, unittest]
import ../utils

suite "Service Discovery Component - Dial Backoff":
  teardown:
    checkTrackers()

  asyncTest "an unreachable peer backs off, then leaves the service table":
    let discoConfig = ServiceDiscoveryConfig.new(
      dialBackoffBase = 1.millis, dialBackoffMax = 1.millis, maxDialFailures = 3
    )
    let disco = setupServiceDiscoveryNode(discoConfig = discoConfig)
    startAndDeferStop(@[disco])

    let service = makeServiceInfo()
    check disco.addProvidedService(service).isOk()
    let table = disco.rtManager.getTable(service.id.hashServiceId()).get()

    let dead = randomPeerId()
    disco.switch.peerStore[AddressBook].set(
      dead, @[ma("/ip4/127.0.0.1/tcp/1")], AddressConfidence.Low
    )
    check table.insert(dead)

    let msg = kad_protobuf.Message(msgType: kad_protobuf.MessageType.ping)

    check (await disco.send(dead, msg)).isErr()

    let backedOff = await disco.send(dead, msg)
    check:
      backedOff.isErr()
      strutils.contains(backedOff.error, "backoff")
      table.contains(dead.toKey())

    for _ in 1 .. 2:
      await sleepAsync(10.millis)
      check (await disco.send(dead, msg)).isErr()

    check not table.contains(dead.toKey())

    # A re-admitted peer must stay backed off, or the eviction only restarts the loop.
    check table.insert(dead)
    let reAdmitted = await disco.send(dead, msg)
    check:
      reAdmitted.isErr()
      strutils.contains(reAdmitted.error, "backoff")
