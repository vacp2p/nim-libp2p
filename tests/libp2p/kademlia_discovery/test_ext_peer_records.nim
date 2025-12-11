# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import stew/byteutils
import ../../../libp2p/[crypto/crypto, peerid, multiaddress, routing_record]
import ../../../libp2p/protocols/kademlia_discovery/[types, protobuf]
import ../../tools/[unittest, crypto]

suite "Extended peer record":
  test "Encoding roundtrip test":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses =
        @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(),
          MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet(),
        ]
      services = @[ServiceInfo(id: "test_service", data: @[])]
      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)

      encoded = extPR.encode()
      decoded = ExtPeerRecord.decode(encoded)

    check:
      decoded.isOk() == true
      decoded.get() == extPR

  test "Interop decode":
    let
      # from https://github.com/libp2p/go-libp2p-core/blob/b18a4c9c5629870bde2cd85ab3b87a507600d411/peer/record_test.go#L33
      # (with only 2 addresses)
      inputData = "0a2600240801122011bba3ed1721948cefb4e50b0a0bb5cad8a6b52dc7b1a40f4f6652105c91e2c4109bf59d8dd99d8ddb161a0a0a0804010203040600001a0a0a080401020304060001".hexToSeqByte()
      decodedRecord = ExtPeerRecord.decode(inputData).tryGet()

    check:
      $decodedRecord.peerId == "12D3KooWB1b3qZxWJanuhtseF3DmPggHCtG36KZ9ixkqHtdKH9fh"
      decodedRecord.seqNo == uint64 1636553709551319707
      decodedRecord.addresses.len == 2
      $decodedRecord.addresses[0].address == "/ip4/1.2.3.4/tcp/0"
      $decodedRecord.addresses[1].address == "/ip4/1.2.3.4/tcp/1"

suite "Signed Extended Peer Record":
  test "Encoding roundtrip test":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses =
        @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(),
          MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet(),
        ]
      services = @[ServiceInfo(id: "test_service", data: @[])]

      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)
      signedExtPR = SignedExtPeerRecord.init(privKey, extPR)

    check signedExtPR.isOk() == true

    let encoded = signedExtPR.get().encode()
    check encoded.isOk() == true

    let decoded = SignedExtPeerRecord.decode(encoded.get())
    check:
      decoded.isOk() == true
      decoded.get() == signedExtPR.get()

  test "Can't use mismatched public key":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      privKey2 = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses =
        @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(),
          MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet(),
        ]
      services = @[ServiceInfo(id: "test_service", data: @[])]
      signedExtPR = SignedExtPeerRecord.init(
        privKey2, ExtPeerRecord.init(peerId, multiAddresses, 42, services)
      )

    check signedExtPR.isOk() == true

    let encoded = signedExtPR.get().encode()

    check:
      encoded.isOk() == true
      SignedExtPeerRecord.decode(encoded.get()).error == EnvelopeInvalidSignature

  test "Decode doesn't fail if some addresses are invalid":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses =
        @[MultiAddress(), MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet()]
      services = @[ServiceInfo(id: "test_service", data: @[])]
      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)

      encoded = extPR.encode()
      decoded = ExtPeerRecord.decode(encoded)

    check:
      decoded.isOk() == true
      decoded.get().addresses.len == 1

  test "Decode doesn't fail if there are no addresses":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses = newSeq[MultiAddress]()
      services = @[ServiceInfo(id: "test_service", data: @[])]
      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)

      encoded = extPR.encode()
      decoded = ExtPeerRecord.decode(encoded)

    check:
      decoded.isOk() == true
      decoded.get().addresses.len == 0

  test "Decode fails if all addresses are invalid":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses = @[MultiAddress(), MultiAddress()]
      services = @[ServiceInfo(id: "test_service", data: @[])]
      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)

    check ExtPeerRecord.decode(extPR.encode()).isErr

  test "Decode doesn't fail if there are no services":
    let
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses =
        @[MultiAddress(), MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet()]
      services: seq[ServiceInfo] = @[]
      extPR = ExtPeerRecord.init(peerId, multiAddresses, 42, services)

      encoded = extPR.encode()
      decoded = ExtPeerRecord.decode(encoded)

    check:
      decoded.isOk() == true
      decoded.get().services.len == 0
