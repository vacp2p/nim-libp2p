# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, results, sets, sequtils, tables
import ../../../libp2p/[protocols/kademlia, switch, builders, multicodec]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT - ProviderManager":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len() == 0

    await kads[1].addProvider(key.toCid())

    # kads[0] has kads[1] in its providermanager after adding provider
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len() == 1
      kads[0].providerManager.providerRecords[0].provider.id == kads[1].rtable.selfId

  asyncTest "Provider expired":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len() == 0

    await kads[1].addProvider(key1.toCid())
    await kads[1].addProvider(key2.toCid())

    # provider records added
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len() == 2

    # provider records expired and evicted after expiration time
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len() == 0

  asyncTest "Adding providers again refreshes expiration time":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len() == 0

    await kads[1].addProvider(key1.toCid())
    await kads[1].addProvider(key2.toCid())

    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len() == 2

    let
      originalExpiresAt1 = kads[0].providerManager.providerRecords[0].expiresAt
      originalExpiresAt2 = kads[0].providerManager.providerRecords[1].expiresAt

    # refresh providers
    await kads[1].addProvider(key1.toCid())
    await kads[1].addProvider(key2.toCid())

    checkUntilTimeout:
      kads[0].providerManager.providerRecords[0].expiresAt > originalExpiresAt1
      kads[0].providerManager.providerRecords[1].expiresAt > originalExpiresAt2

  asyncTest "Start/stop providing":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # key1 is provided with startProviding
    # key2 is manually sent once with addProvider
    await kads[0].startProviding(key1.toCid())
    await kads[0].addProvider(key2.toCid())

    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len() == 2
      kads[1].providerManager.knownKeys.len() == 2
      kads[0].providerManager.providedKeys.len() == 1

    # after the expiration time only key2 expired
    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len() == 1
      kads[1].providerManager.knownKeys.len() == 1
      kads[0].providerManager.providedKeys.len() == 1

    # stop providing key
    kads[0].stopProviding(key1.toCid())

    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len() == 0
      kads[1].providerManager.knownKeys.len() == 0
      kads[0].providerManager.providedKeys.len() == 0

  asyncTest "Provider limits":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodesStar(kads)

    let
      key1 = kads[0].rtable.selfId
      cid1 = key1.toCid()
      key2 = kads[1].rtable.selfId
      cid2 = key2.toCid()

    # set low capacities
    kads[0].providerManager.providedKeys.capacity = 1
    kads[1].providerManager.providerRecords.capacity = 1

    await kads[0].startProviding(cid1)

    checkUntilTimeout:
      kads[0].providerManager.providedKeys.hasKey(cid1.toKey())
      kads[0].providerManager.providedKeys.len() == 1
      kads[1].providerManager.providerRecords.len() == 1

    # start providing overwrites key1 with key2 due to low capacity (1)
    await kads[0].startProviding(cid2)

    checkUntilTimeout:
      not kads[0].providerManager.providedKeys.hasKey(cid1.toKey())
      kads[0].providerManager.providedKeys.hasKey(cid2.toKey())
      kads[0].providerManager.providedKeys.len() == 1
      kads[1].providerManager.providerRecords.len() == 1

  asyncTest "Get providers - iterative lookup":
    let kads = await setupKadSwitches(
      4,
      cleanupProvidersInterval = 1.seconds(),
      republishProvidedKeysInterval = 1.seconds(),
    )
    defer:
      await stopNodes(kads)

    # topology: kads[0] <-> kads[1] <-> kads[2] <-> kads[3]
    connectNodes(kads[0], kads[1])
    connectNodes(kads[1], kads[2])
    connectNodes(kads[2], kads[3])

    let
      key = kads[0].rtable.selfId
      cid = key.toCid()

    # Add key to kads[3] providedKeys locally (without broadcasting via addProvider)
    kads[3].providerManager.providedKeys.provided[key] = Moment.now()

    # Verify other nodes don't know about the provider yet
    check:
      kads[0].providerManager.providerRecords.len() == 0
      kads[1].providerManager.providerRecords.len() == 0
      kads[2].providerManager.providerRecords.len() == 0

    # kad0 iteratively queries the network and should find kad3 as a provider
    let providers = await kads[0].getProviders(key)

    # kad3 should be found as the provider
    check:
      providers.len() == 1
      providers.toSeq()[0].id == kads[3].switch.peerInfo.peerId.getBytes()

    checkUntilTimeout:
      # Provider records have propagated
      kads[0].providerManager.providerRecords.len() == 1
      kads[1].providerManager.providerRecords.len() == 1
      kads[2].providerManager.providerRecords.len() == 1
      # Other peers have been discovered
      kads[0].hasKey(kads[2].rtable.selfId)
      kads[0].hasKey(kads[3].rtable.selfId)

    # Query for unknown key is handled
    check (await kads[0].getProviders(@[1.byte, 1, 1, 1])).len == 0
