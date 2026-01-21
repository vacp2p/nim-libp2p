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
import
  ../../../libp2p/[protocols/kademlia, switch, builders, multicodec, multihash, cid]
import ../../tools/[unittest]
import ./[utils]

suite "KadDHT - Get Providers":
  teardown:
    checkTrackers()

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

  asyncTest "GetProviders updates routing table with closerPeers (no providers)":
    # kads[2] <---> kads[0] (hub) <---> kads[1]
    let kads = await setupKadSwitches(
      3,
      PermissiveValidator(),
      CandSelector(),
      @[],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    let key = kads[0].rtable.selfId

    check:
      kads[2].hasKey(kads[0].rtable.selfId)
      not kads[2].hasKey(kads[1].rtable.selfId)

    # When kads[0] doesn't have any providers, handleGetProviders returns only closerPeers
    let providers = await kads[2].getProviders(key)

    # kads[2] should discover kads[1] through the closerPeers in the response
    check:
      providers.len() == 0
      kads[2].hasKey(kads[1].rtable.selfId) # discovered via closerPeers

  asyncTest "GetProviders updates routing table with closerPeers (with providers)":
    # kads[2] <---> kads[0] (hub) <---> kads[1]
    let kads = await setupKadSwitches(
      3,
      PermissiveValidator(),
      CandSelector(),
      @[],
      chronos.seconds(1),
      chronos.seconds(1),
    )
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])
    connectNodes(kads[0], kads[2])

    let key = kads[0].rtable.selfId

    # kads[0] is providing the key
    kads[0].providerManager.providedKeys.provided[key] = Moment.now()

    check:
      kads[2].hasKey(kads[0].rtable.selfId)
      not kads[2].hasKey(kads[1].rtable.selfId)

    # When kads[0] has providers, handleGetProviders returns both providers and closerPeers
    let providers = await kads[2].getProviders(key)

    # kads[2] should discover kads[1] through the closerPeers in the response
    check:
      providers.len() == 1
      kads[2].hasKey(kads[1].rtable.selfId) # discovered via closerPeers

  asyncTest "GetProviders uses multihash for CID convergence":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    # Create two CIDs with same multihash but different codecs
    let
      testData = @[1.byte, 2, 3, 4, 5]
      mhash = MultiHash.digest("sha2-256", testData).get()
      cidDagPb = Cid.init(CIDv1, multiCodec("dag-pb"), mhash).get()
      cidRaw = Cid.init(CIDv1, multiCodec("raw"), mhash).get()
      expectedKey = mhash.toKey()

    # Verify CIDs are different but map to same key
    check:
      cidDagPb.data.buffer != cidRaw.data.buffer
      cidDagPb.toKey() == cidRaw.toKey()

    # kads[1] announces as provider using dag-pb CID key
    kads[1].providerManager.providedKeys.provided[expectedKey] = Moment.now()

    # kads[0] queries using raw CID - should find the same provider
    let providers = await kads[0].getProviders(cidRaw.toKey())

    check:
      providers.len() == 1
      providers.toSeq()[0].id == kads[1].switch.peerInfo.peerId.getBytes()
