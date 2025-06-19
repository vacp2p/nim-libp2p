{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options
import chronos
import
  ../../libp2p/crypto/crypto,
  ../../libp2p/multicodec,
  ../../libp2p/peerinfo,
  ../../libp2p/peerid,
  ../../libp2p/routing_record

import ../helpers

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    var peerInfo = PeerInfo.new(seckey)
    var peerId = PeerId.init(seckey).get()

    check peerId == peerInfo.peerId
    check seckey.getPublicKey().get() == peerInfo.publicKey

  test "Signed peer record":
    const
      ExpectedDomain = $multiCodec("libp2p-peer-record")
      ExpectedPayloadType = @[(byte) 0x03, (byte) 0x01]

    let
      seckey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(seckey).get()
      multiAddresses =
        @[
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
      env.domain == ExpectedDomain
      env.payloadType == ExpectedPayloadType

    # Check payload (routing record)
    check:
      rec.peerId == peerId
      rec.seqNo > 0
      rec.addresses.len == 2
      rec.addresses[0].address == multiAddresses[0]
      rec.addresses[1].address == multiAddresses[1]

  test "Public address mapping":
    let
      seckey = PrivateKey.random(ECDSA, rng[]).get()
      multiAddresses =
        @[
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
