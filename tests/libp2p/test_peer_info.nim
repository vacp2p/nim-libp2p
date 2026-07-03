{.used.}

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos
import
  ../../libp2p/crypto/crypto,
  ../../libp2p/multicodec,
  ../../libp2p/peerinfo,
  ../../libp2p/peerid,
  ../../libp2p/routing_record
import ../tools/[unittest, crypto]

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(ECDSA, rng()).get()
    var peerInfo = PeerInfo.new(seckey)
    var peerId = PeerId.init(seckey).get()

    check peerId == peerInfo.peerId
    check seckey.getPublicKey().get() == peerInfo.publicKey

  test "Signed peer record":
    const
      ExpectedDomain = $multiCodec("libp2p-peer-record")
      ExpectedPayloadType = @[(byte) 0x03, (byte) 0x01]

    let
      seckey = PrivateKey.random(rng()).tryGet()
      peerId = PeerId.init(seckey).get()
      multiAddresses = @[
        MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet(),
      ]
      peerInfo = PeerInfo.new(seckey, multiAddresses)

    waitFor(peerInfo.update())

    let
      env = peerInfo.signedPeerRecord.envelope
      rec = PeerRecord.decode(env.payload()).tryGet()

    # Check envelope fields
    check:
      env.publicKey == peerInfo.publicKey
      env.payloadType == ExpectedPayloadType
      env.verify(ExpectedDomain)

    # Check payload (routing record)
    check:
      rec.peerId == peerId
      rec.seqNo > 0
      rec.addresses.len == 2
      rec.addresses[0].address == multiAddresses[0]
      rec.addresses[1].address == multiAddresses[1]

  test "Public address mapping":
    let
      seckey = PrivateKey.random(ECDSA, rng()).get()
      multiAddresses = @[
        MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet(),
      ]
      multiAddresses2 = @[MultiAddress.init("/ip4/8.8.8.8/tcp/33").tryGet()]

    proc addressMapper(
        input: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      check input == multiAddresses
      await sleepAsync(0.seconds)
      return multiAddresses2

    var peerInfo =
      PeerInfo.new(seckey, multiAddresses, addressMappers = @[addressMapper])
    waitFor peerInfo.update()
    check peerInfo.addrs == multiAddresses2

  test "Announced addresses override mapper chain":
    let
      seckey = PrivateKey.random(ECDSA, rng()).get()
      listenAddrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet()]
      mapperAddrs = @[MultiAddress.init("/ip4/8.8.8.8/tcp/33").tryGet()]
      announcedAddrs = @[
        MultiAddress.init("/ip4/203.0.113.7/tcp/9000").tryGet(),
        MultiAddress.init("/ip4/203.0.113.7/udp/9000/quic-v1").tryGet(),
      ]

    var mapperCalled = false
    proc addressMapper(
        input: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      mapperCalled = true
      return mapperAddrs

    let peerInfo = PeerInfo.new(
      seckey,
      listenAddrs,
      addressMappers = @[addressMapper],
      announcedAddrs = announcedAddrs,
    )
    waitFor peerInfo.update()

    # announcedAddrs wins: mapper chain is bypassed entirely
    check:
      peerInfo.addrs == announcedAddrs
      mapperCalled == false

  test "addressPolicy still filters announced addresses":
    let
      seckey = PrivateKey.random(ECDSA, rng()).get()
      publicAddr = MultiAddress.init("/ip4/203.0.113.7/tcp/9000").tryGet()
      privateAddr = MultiAddress.init("/ip4/192.168.1.42/tcp/9000").tryGet()
      announcedAddrs = @[publicAddr, privateAddr]

    proc onlyPublic(ma: MultiAddress): bool {.gcsafe, raises: [].} =
      ma == publicAddr

    let peerInfo = PeerInfo.new(
      seckey, [], addressPolicy = onlyPublic, announcedAddrs = announcedAddrs
    )
    waitFor peerInfo.update()

    check peerInfo.addrs == @[publicAddr]

  test "Observers fire on notifyObservers":
    let
      seckey = PrivateKey.random(ECDSA, rng()).get()
      multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").get()]
      peerInfo = PeerInfo.new(seckey, multiAddresses)

    var
      callsA = 0
      callsB = 0

    proc obsA(p: PeerInfo) {.gcsafe, raises: [].} =
      inc callsA

    proc obsB(p: PeerInfo) {.gcsafe, raises: [].} =
      inc callsB

    peerInfo.addObserver(obsA)
    peerInfo.addObserver(obsB)
    peerInfo.addObserver(nil) # nil guard: must be no-op

    peerInfo.notifyObservers()
    check:
      callsA == 1
      callsB == 1

    peerInfo.notifyObservers()
    check:
      callsA == 2
      callsB == 2

    # removed observer is not triggered
    peerInfo.removeObserver(obsA)
    peerInfo.notifyObservers()
    check:
      callsA == 2
      callsB == 3

  test "Observers fire on update":
    let
      seckey = PrivateKey.random(ECDSA, rng()).get()
      multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").get()]
      peerInfo = PeerInfo.new(seckey, multiAddresses)

    var
      calls: int
      seenAddrs: seq[MultiAddress]

    proc obs(p: PeerInfo) {.gcsafe, raises: [].} =
      inc calls
      seenAddrs = p.addrs

    peerInfo.addObserver(obs)

    # updated triggers observers initially
    # (PeerInfo.new does not set up `.addrs` property initially)
    waitFor peerInfo.update()
    check:
      calls == 1
      seenAddrs == peerInfo.addrs

    # update won't trigger observers since `.addrs` was not changed
    waitFor peerInfo.update()
    check:
      calls == 1
