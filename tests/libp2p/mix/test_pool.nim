# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../../libp2p/[crypto/crypto, crypto/secp, multiaddress, peerid, peerstore]
import ../../../libp2p/protocols/mix/[mix_node, pool]
import ../../tools/unittest

suite "MixNodePool Tests":
  var
    peerStore {.threadvar.}: PeerStore
    pool {.threadvar.}: MixNodePool
    mixNodes {.threadvar.}: MixNodes

  setup:
    peerStore = PeerStore.new()
    pool = MixNodePool.new(peerStore)
    mixNodes = initializeMixNodes(5).expect("could not generate mix nodes")

  teardown:
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  test "new creates empty pool":
    check pool.len == 0

  test "add stores mix node info":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)

    check:
      pool.len == 1
      pool.get(pubInfo.peerId).isSome
      pool.get(pubInfo.peerId).get() == pubInfo

  test "add stores all required data in peerStore":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)

    check:
      peerStore[MixPubKeyBook][pubInfo.peerId] == pubInfo.mixPubKey
      peerStore[AddressBook][pubInfo.peerId] == @[pubInfo.multiAddr]
      peerStore[KeyBook][pubInfo.peerId].scheme == Secp256k1
      peerStore[KeyBook][pubInfo.peerId].skkey == pubInfo.libp2pPubKey

  test "remove deletes from pool":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)
    check pool.len == 1

    let removed = pool.remove(pubInfo.peerId)

    check:
      removed == true
      pool.len == 0
      pool.get(pubInfo.peerId).isNone

  test "remove returns false for non-existent peer":
    let peerId = PeerId.random().expect("could not generate peerId")
    check pool.remove(peerId) == false

  test "get returns none for non-existent peer":
    let peerId = PeerId.random().expect("could not generate peerId")
    check pool.get(peerId).isNone

  test "get returns none when address is missing":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    # Manually add only the mix key, not the address
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey

    check pool.get(pubInfo.peerId).isNone

  test "get returns none when key scheme is not Secp256k1":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    # Manually add with wrong key scheme
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[AddressBook][pubInfo.peerId] = @[pubInfo.multiAddr]
    # KeyBook is not set, so scheme defaults to something other than Secp256k1

    check pool.get(pubInfo.peerId).isNone

  test "get returns none when only IPv6 address is available":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")
    let ipv6Addr =
      MultiAddress.init("/ip6/::1/tcp/4242").expect("could not create IPv6 multiaddr")

    # Add node with only IPv6 address
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6Addr]
    peerStore[KeyBook][pubInfo.peerId] =
      PublicKey(scheme: Secp256k1, skkey: pubInfo.libp2pPubKey)

    # Should return none since mix only supports IPv4
    check pool.get(pubInfo.peerId).isNone

  test "get returns IPv4 address when mixed addresses are available":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")
    let ipv6Addr =
      MultiAddress.init("/ip6/::1/tcp/4242").expect("could not create IPv6 multiaddr")
    let ipv4Addr = MultiAddress.init("/ip4/127.0.0.1/tcp/4243").expect(
        "could not create IPv4 multiaddr"
      )

    # Add node with both IPv6 and IPv4 addresses (IPv6 first)
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6Addr, ipv4Addr]
    peerStore[KeyBook][pubInfo.peerId] =
      PublicKey(scheme: Secp256k1, skkey: pubInfo.libp2pPubKey)

    let result = pool.get(pubInfo.peerId)
    check:
      result.isSome
      result.get().multiAddr == ipv4Addr

  test "peerIds returns all peer IDs":
    for i in 0 ..< mixNodes.len:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    let peerIds = pool.peerIds()

    check peerIds.len == mixNodes.len

    for i in 0 ..< mixNodes.len:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      check pubInfo.peerId in peerIds

  test "len returns correct count":
    check pool.len == 0

    for i in 0 ..< 3:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)
      check pool.len == i + 1

  test "multiple operations sequence":
    # Add 3 nodes
    for i in 0 ..< 3:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    check pool.len == 3

    # Remove middle node
    let middlePubInfo =
      mixNodes.getMixPubInfoByIndex(1).expect("could not get pub info")
    discard pool.remove(middlePubInfo.peerId)

    check:
      pool.len == 2
      pool.get(middlePubInfo.peerId).isNone

    # Add two more nodes
    for i in 3 ..< 5:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    check pool.len == 4
