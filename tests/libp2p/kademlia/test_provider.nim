# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[tables, sets, sequtils]
from std/times import now, utc
import chronos, chronicles
import ../../../libp2p/[protocols/kademlia, switch, builders, multicodec]
import ../../tools/[unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "KadDHT - ProviderManager":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)
    kad2.dataTable.insert(key, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.providerRecords.len() == 0

    await kad2.addProvider(key.toCid())
    await sleepAsync(10.milliseconds)

    # kad1 has kad2 in its providermanager after adding provider
    check:
      kad1.providerManager.providerRecords.len() == 1
      kad1.providerManager.providerRecords[0].provider.id == kad2.rtable.selfId

  asyncTest "Provider expired":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key1, value, $times.now().utc)
    kad2.dataTable.insert(key2, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.providerRecords.len() == 0

    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())
    await sleepAsync(10.milliseconds)

    check kad1.providerManager.providerRecords.len() == 2

    # wait less than expiration time
    await sleepAsync(kad1.config.cleanupProvidersInterval)

    # provider records have not yet expired
    check kad1.providerManager.providerRecords.len() == 2

    # wait expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    # provider records expired and evicted
    check kad1.providerManager.providerRecords.len() == 0

  asyncTest "Provider refreshed (not expired)":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad2.dataTable.insert(key1, value, $times.now().utc)
    kad2.dataTable.insert(key2, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.providerRecords.len() == 0

    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())
    await sleepAsync(10.milliseconds)

    check kad1.providerManager.providerRecords.len() == 2

    # wait less than expiration time
    await sleepAsync(kad1.config.cleanupProvidersInterval)

    # provider records have not yet expired
    check kad1.providerManager.providerRecords.len() == 2

    # refresh providers
    await kad2.addProvider(key1.toCid())
    await kad2.addProvider(key2.toCid())

    # wait rest of expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval - 2 * kad1.config.cleanupProvidersInterval
    )

    # provider records have not expired (refreshed)
    check kad1.providerManager.providerRecords.len() == 2

    # wait expiration time
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    # provider records have expired
    check kad1.providerManager.providerRecords.len() == 0

  asyncTest "Start/stop providing":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop())

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
      kad2.providerManager.providerRecords.len() == 2
      kad2.providerManager.knownKeys.len() == 2

    # after the expiration time only key2 expired
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )

    check:
      kad1.providerManager.providedKeys.len() == 1
      kad2.providerManager.providerRecords.len() == 1
      kad2.providerManager.knownKeys.len() == 1

    # stop providing key
    kad1.stopProviding(key1.toCid())

    # after the expiration time, key1 expired
    await sleepAsync(
      kad1.config.providerExpirationInterval + 2 * kad1.config.cleanupProvidersInterval
    )
    check:
      kad1.providerManager.providedKeys.len() == 0
      kad2.providerManager.providerRecords.len() == 0
      kad2.providerManager.knownKeys.len() == 0

  asyncTest "Provider limits":
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch3, kad3) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch4, kad4) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch1, kad1) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[
        (switch2.peerInfo.peerId, switch2.peerInfo.addrs),
        (switch3.peerInfo.peerId, switch3.peerInfo.addrs),
        (switch4.peerInfo.peerId, switch4.peerInfo.addrs),
      ],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop())

    let
      key1 = kad1.rtable.selfId
      cid1 = key1.toCid()
      key2 = kad2.rtable.selfId
      cid2 = key2.toCid()
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key1, value, $times.now().utc)
    kad1.dataTable.insert(key2, value, $times.now().utc)

    # set low capacities
    kad1.providerManager.providedKeys.capacity = 1
    kad2.providerManager.providerRecords.capacity = 1

    await kad1.startProviding(cid1)
    await sleepAsync(100.milliseconds)
    let keyBefore = kad2.providerManager.providerRecords[0].key
    check:
      kad1.providerManager.providedKeys.len() == 1
      kad1.providerManager.providedKeys.hasKey(cid1)
      kad2.providerManager.providerRecords.len() == 1

    # setting capacity means we overwrite key1
    await kad1.startProviding(cid2)
    await sleepAsync(100.milliseconds)
    let keyAfter = kad2.providerManager.providerRecords[0].key
    check:
      kad1.providerManager.providedKeys.len() == 1
      kad1.providerManager.providedKeys.hasKey(cid2)
      not kad1.providerManager.providedKeys.hasKey(cid1)
      kad2.providerManager.providerRecords.len() == 1
      keyBefore != keyAfter

  asyncTest "Get providers":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch3, kad3) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[
        (switch1.peerInfo.peerId, switch1.peerInfo.addrs),
        (switch3.peerInfo.peerId, switch3.peerInfo.addrs),
      ],
    )
    defer:
      await allFutures(switch1.stop(), switch2.stop(), switch3.stop())

    discard await kad2.findNode(kad1.rtable.selfId)
    discard await kad2.findNode(kad3.rtable.selfId)

    let
      key1 = kad1.rtable.selfId
      key2 = kad2.rtable.selfId
      key3 = kad3.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    # don't call startProviding directly to avoid sending addProvider
    # this will force asking peer to use closerPeers
    kad2.dataTable.insert(key2, value, $times.now().utc)
    kad2.providerManager.providedKeys.provided[key2.toCid()] = chronos.Moment.now()

    kad3.dataTable.insert(key3, value, $times.now().utc)
    kad3.providerManager.providedKeys.provided[key3.toCid()] = chronos.Moment.now()

    # kad1 <-> kad2 <-> kad3
    #          key2     key3

    let providers = (await kad1.getProviders(key2)).toSeq()
    check providers[0].id == kad2.rtable.selfId

    # kad2 doesn't provide key3, but returns closerPeers
    let (rawProviders, closerPeers) =
      await kad1.dispatchGetProviders(kad2.switch.peerInfo.peerId, key3)

    check:
      rawProviders.len() == 0
      closerPeers.toPeerIds()[0] == kad3.switch.peerInfo.peerId

    # we can still get key3 because getProviders is iterative
    let providers3 = (await kad1.getProviders(key3)).toSeq()
    check providers3[0].id == kad3.rtable.selfId

    # timeout is handled
    let providers1 = (await kad1.getProviders(key1)).toSeq()
    check providers1.len == 0
