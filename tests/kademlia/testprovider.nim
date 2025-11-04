# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[heapqueue, tables]
from std/times import now, utc
import chronos, chronicles
import ../../libp2p/[protocols/kademlia, switch, builders]
import ../tools/[unittest]
import ./utils.nim

suite "KadDHT - ProviderManager":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad1.bootstrap(@[switch2.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)
    kad2.dataTable.insert(key, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.records.len() == 0

    await kad2.addProvider(key.toCid())
    await sleepAsync(10.milliseconds)

    # kad1 has kad2 in its providermanager after adding provider
    check:
      kad1.providerManager.records.len() == 1
      kad1.providerManager.records[0].provider.id == kad2.rtable.selfId

  asyncTest "Provider expired":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad1.bootstrap(@[switch2.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key1, value, $times.now().utc)
    kad2.dataTable.insert(key2, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.records.len() == 0

    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())
    await sleepAsync(10.milliseconds)

    check kad1.providerManager.records.len() == 2

    # wait less than expiration time
    await sleepAsync(kad1.config.cleanupProvidersInterval)

    # provider records have not yet expired
    check kad1.providerManager.records.len() == 2

    # wait expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    # provider records expired and evicted
    check kad1.providerManager.records.len() == 0

  asyncTest "Provider refreshed (not expired)":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad1.bootstrap(@[switch2.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key1, value, $times.now().utc)
    kad2.dataTable.insert(key2, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.records.len() == 0

    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())
    await sleepAsync(10.milliseconds)

    check kad1.providerManager.records.len() == 2

    # wait less than expiration time
    await sleepAsync(kad1.config.cleanupProvidersInterval)

    # provider records have not yet expired
    check kad1.providerManager.records.len() == 2

    # refresh providers
    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())

    # wait rest of expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval - kad1.config.cleanupProvidersInterval
    )

    # provider records have not expired (refreshed)
    check kad1.providerManager.records.len() == 2

    # wait expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    # provider records have expired
    check kad1.providerManager.records.len() == 0

  asyncTest "Start/stop providing":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad1.bootstrap(@[switch2.peerInfo])

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key1, value, $times.now().utc)
    kad1.dataTable.insert(key2, value, $times.now().utc)

    # key1 is provided with startProviding
    # key2 is manually sent once with addProvider
    await kad1.startProviding(key1.toCid())
    await kad1.addProvider(key2.toCid())
    await sleepAsync(10.milliseconds)

    check:
      kad1.providerManager.providedKeys.len() == 1
      kad2.providerManager.records.len() == 2
      kad2.providerManager.knownKeys.len() == 2

    # after the expiration time only key2 expired
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    check:
      kad1.providerManager.providedKeys.len() == 1
      kad2.providerManager.records.len() == 1
      kad2.providerManager.knownKeys.len() == 1

    # stop providing key
    kad1.stopProviding(key1.toCid())

    # after the expiration time, key1 expired
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )
    check:
      kad1.providerManager.providedKeys.len() == 0
      kad2.providerManager.records.len() == 0
      kad2.providerManager.knownKeys.len() == 0
