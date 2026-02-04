# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, sets, sequtils, tables
import
  ../../../libp2p/[protocols/kademlia, switch, builders, multicodec, multihash, cid]
import ../../tools/[unittest]
import ./[mock_kademlia, utils]

proc isAtMaxCapacity(providerRecords: ProviderRecords): bool =
  providerRecords.len == providerRecords.capacity

proc isAtMaxCapacity(providedKeys: ProvidedKeys): bool =
  providedKeys.len == providedKeys.capacity

suite "KadDHT - Add Provider":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len == 0

    await kads[1].addProvider(key.toCid())

    # kads[0] has kads[1] in its providermanager after adding provider
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 1
      kads[0].providerManager.providerRecords[0].provider.id == kads[1].rtable.selfId

  asyncTest "Provider expired":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len == 0

    await kads[1].addProvider(key1.toCid())
    await kads[1].addProvider(key2.toCid())

    # provider records added
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 2

    # provider records expired and evicted after expiration time
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 0

  asyncTest "Adding providers again refreshes expiration time":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # ensure providermanager is empty
    check kads[0].providerManager.providerRecords.len == 0

    await kads[1].addProvider(key1.toCid())
    await kads[1].addProvider(key2.toCid())

    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 2

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
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    let
      key1 = kads[0].rtable.selfId
      key2 = kads[1].rtable.selfId

    # key1 is provided with startProviding
    # key2 is manually sent once with addProvider
    await kads[0].startProviding(key1.toCid())
    await kads[0].addProvider(key2.toCid())

    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len == 2
      kads[1].providerManager.knownKeys.len == 2
      kads[0].providerManager.providedKeys.len == 1

    # after the expiration time only key2 expired
    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len == 1
      kads[1].providerManager.knownKeys.len == 1
      kads[0].providerManager.providedKeys.len == 1

    # stop providing key
    kads[0].stopProviding(key1.toCid())

    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len == 0
      kads[1].providerManager.knownKeys.len == 0
      kads[0].providerManager.providedKeys.len == 0

  asyncTest "Provider limits":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodesStar(kads)

    let
      key1 = kads[0].rtable.selfId
      cid1 = key1.toCid()
      key2 = kads[1].rtable.selfId
      cid2 = key2.toCid()
      mhash3 = MultiHash.digest("sha2-256", @[1.byte, 2, 3]).get()
      cid3 = Cid.init(CIDv1, multiCodec("raw"), mhash3).get()

    kads[0].providerManager.providedKeys.capacity = 2 # max keys node can store
    kads[1].providerManager.providerRecords.capacity = 1
      # max provider records node stores from others

    await kads[0].startProviding(cid1)

    checkUntilTimeout:
      kads[0].providerManager.providedKeys.hasKey(cid1.toKey())
      kads[0].providerManager.providedKeys.len == 1
      kads[1].providerManager.knownKeys.hasKey(cid1.toKey())
      kads[1].providerManager.providerRecords.isAtMaxCapacity()

    await kads[0].startProviding(cid2)

    checkUntilTimeout:
      # kads[0] (sender): capacity=2, so both cid1 and cid2 fit
      kads[0].providerManager.providedKeys.hasKey(cid1.toKey())
      kads[0].providerManager.providedKeys.hasKey(cid2.toKey())
      kads[0].providerManager.providedKeys.isAtMaxCapacity()
      # kads[1] (receiver): capacity=1, cid1 evicted, only cid2 remains
      not kads[1].providerManager.knownKeys.hasKey(cid1.toKey())
      kads[1].providerManager.knownKeys.hasKey(cid2.toKey())
      kads[1].providerManager.providerRecords.isAtMaxCapacity()

    await kads[0].startProviding(cid3)

    checkUntilTimeout:
      # kads[0] (sender): cid1 (oldest) evicted, cid2 and cid3 remain
      not kads[0].providerManager.providedKeys.hasKey(cid1.toKey())
      kads[0].providerManager.providedKeys.hasKey(cid2.toKey())
      kads[0].providerManager.providedKeys.hasKey(cid3.toKey())
      kads[0].providerManager.providedKeys.isAtMaxCapacity()
      # kads[1] (receiver): capacity=1, cid2 evicted, only cid3 remains
      not kads[1].providerManager.knownKeys.hasKey(cid1.toKey())
      not kads[1].providerManager.knownKeys.hasKey(cid2.toKey())
      kads[1].providerManager.knownKeys.hasKey(cid3.toKey())
      kads[1].providerManager.providerRecords.isAtMaxCapacity()

  asyncTest "Add provider accepts matching PeerID and rejects mismatched PeerID":
    # Setup sender and imposter KadDHT instances
    let kads = setupKadSwitches(2)

    let
      senderKad = kads[0]
      imposterKad = kads[1]

    # Setup receiver
    var receiverKad = setupMockKad()

    startNodesAndDeferStop(kads & receiverKad)

    connectNodes(senderKad, receiverKad)

    let
      targetKey = senderKad.rtable.selfId
      senderPeer = senderKad.switch.peerInfo.toPeer() # Valid: matches connection
      imposterPeer = imposterKad.switch.peerInfo.toPeer() # Invalid: doesn't match sender

    check receiverKad.providerManager.providerRecords.len == 0

    # Inject a custom message with an imposter peer
    receiverKad.handleAddProviderMessage = Opt.some(
      Message(
        msgType: MessageType.addProvider, key: targetKey, providerPeers: @[imposterPeer]
      )
    )
    await senderKad.addProvider(targetKey.toCid())

    # Verify imposter provider was filtered out
    await sleepAsync(200.milliseconds)
    check receiverKad.providerManager.providerRecords.len == 0

    # Verify valid provider is stored
    receiverKad.handleAddProviderMessage = Opt.none(Message)
    await senderKad.addProvider(targetKey.toCid())

    checkUntilTimeout:
      receiverKad.providerManager.providerRecords.len == 1
      receiverKad.providerManager.providerRecords[0].provider.id ==
        senderKad.switch.peerInfo.peerId.getBytes()

  asyncTest "Add provider rejects invalid multihash key":
    let kads = setupKadSwitches(1)

    let senderKad = kads[0]

    # Setup receiver with mock that injects invalid multihash key
    var receiverKad = setupMockKad()

    startNodesAndDeferStop(kads & receiverKad)

    connectNodes(senderKad, receiverKad)

    check receiverKad.providerManager.providerRecords.len == 0

    # Inject message with invalid multihash key
    receiverKad.handleAddProviderMessage = Opt.some(
      Message(
        msgType: MessageType.addProvider,
        key: @[1.byte, 1, 1],
        providerPeers: @[senderKad.switch.peerInfo.toPeer()],
      )
    )
    await senderKad.addProvider(senderKad.rtable.selfId.toCid())

    # Provider should NOT be stored due to invalid multihash validation
    await sleepAsync(200.milliseconds)
    check receiverKad.providerManager.providerRecords.len == 0

  asyncTest "Add provider with CID key extracts multihash":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    # Create a multihash and two CIDs with same multihash but different codecs
    let
      testData = @[1.byte, 2, 3, 4, 5]
      mhash = MultiHash.digest("sha2-256", testData).get()
      cidDagPb = Cid.init(CIDv1, multiCodec("dag-pb"), mhash).get()
      cidRaw = Cid.init(CIDv1, multiCodec("raw"), mhash).get()
      expectedKey = mhash.toKey()

    check:
      cidDagPb.data.buffer != cidRaw.data.buffer # Different CID bytes
      cidDagPb.toKey() == cidRaw.toKey() # Same extracted key
      cidDagPb.toKey() == expectedKey

    check kads[0].providerManager.providerRecords.len == 0

    # Add provider using CIDv1 dag-pb
    await kads[1].addProvider(cidDagPb)

    # Provider record should be stored with multihash as key
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 1
      kads[0].providerManager.providerRecords[0].key == expectedKey
      kads[0].providerManager.providerRecords[0].provider.id == kads[1].rtable.selfId

    let originalExpiresAt = kads[0].providerManager.providerRecords[0].expiresAt

    # Add provider using CIDv1 raw with same multihash - should update same key
    await kads[1].addProvider(cidRaw)

    # Should still have one record (same key) with refreshed expiration
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 1
      kads[0].providerManager.providerRecords[0].key == expectedKey
      kads[0].providerManager.providerRecords[0].expiresAt > originalExpiresAt

  asyncTest "Multiple providers for same CID":
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # kads[0] is receiver, kads[1] and kads[2] are providers
    connectNodesHub(kads[0], kads[1 ..^ 1])

    let targetCid = kads[0].rtable.selfId.toCid()

    check kads[0].providerManager.providerRecords.len == 0

    # First provider announces
    await kads[1].addProvider(targetCid)

    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 1

    # Second provider announces same CID
    await kads[2].addProvider(targetCid)

    # Both providers should be stored
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 2

    let providers = kads[0].providerManager.knownKeys[targetCid.toKey()]
    check:
      providers.len == 2
      kads[1].rtable.selfId in providers.mapIt(it.id)
      kads[2].rtable.selfId in providers.mapIt(it.id)

  asyncTest "Provider address storage policy - addresses may be omitted":
    let kads = setupKadSwitches(1)
    let senderKad = kads[0]
    var receiverKad = setupMockKad()

    startNodesAndDeferStop(kads & receiverKad)

    connectNodes(senderKad, receiverKad)

    check receiverKad.providerManager.providerRecords.len == 0

    # Inject message with provider that has no addresses
    let
      targetKey = senderKad.rtable.selfId
      # Provider with empty addresses
      providerWithNoAddrs = Peer(
        id: senderKad.switch.peerInfo.peerId.getBytes(),
        addrs: @[],
        connection: ConnectionType.connected,
      )
    receiverKad.handleAddProviderMessage = Opt.some(
      Message(
        msgType: MessageType.addProvider,
        key: targetKey,
        providerPeers: @[providerWithNoAddrs],
      )
    )
    await senderKad.addProvider(targetKey.toCid())

    # Provider should be stored even without addresses
    checkUntilTimeout:
      receiverKad.providerManager.providerRecords.len == 1
      receiverKad.providerManager.providerRecords[0].provider.id ==
        senderKad.switch.peerInfo.peerId.getBytes()
      receiverKad.providerManager.providerRecords[0].provider.addrs.len == 0

  asyncTest "Add provider includes local multiaddresses":
    let kads = setupKadSwitches(2)
    startNodesAndDeferStop(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId

    # Inject additional multiaddresses to verify all are included
    kads[1].switch.peerInfo.addrs.add(
      MultiAddress.init("/ip4/192.168.1.100/tcp/4001").get()
    )
    kads[1].switch.peerInfo.addrs.add(MultiAddress.init("/ip6/::1/tcp/4001").get())

    check kads[0].providerManager.providerRecords.len == 0

    await kads[1].addProvider(key.toCid())

    # Verify provider record includes sender's multiaddresses
    checkUntilTimeout:
      kads[0].providerManager.providerRecords.len == 1

    let storedProvider = kads[0].providerManager.providerRecords[0].provider
    check:
      storedProvider.id == kads[1].rtable.selfId
      storedProvider.addrs == kads[1].switch.peerInfo.addrs

  asyncTest "Add provider completes when some peers fail":
    let kads = setupKadSwitches(3)
    startNodesAndDeferStop(kads)

    # Setup: kads[0] is sender, kads[1] and kads[2] are potential receivers
    connectNodesHub(kads[0], kads[1 ..^ 1])

    let key = kads[0].rtable.selfId

    # Stop one receiver to simulate failure
    await kads[2].switch.stop()

    # Add provider should complete despite one peer failing
    await kads[0].addProvider(key.toCid())

    # Verify provider was stored at the successful receiver
    checkUntilTimeout:
      kads[1].providerManager.providerRecords.len == 1
      kads[1].providerManager.providerRecords[0].provider.id == kads[0].rtable.selfId
