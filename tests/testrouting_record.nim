import unittest2
import stew/byteutils
import ../libp2p/[routing_record, crypto/crypto]

suite "Routing record":
  test "Encode -> decode test":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerId.init(privKey).tryGet()
      multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet()]
      routingRecord = PeerRecord.init(peerId, 42, multiAddresses)

      buffer = routingRecord.encode()

      parsedRR = PeerRecord.decode(buffer).tryGet()

    check:
      parsedRR.peerId == peerId
      parsedRR.seqNo == 42
      parsedRR.addresses.len == 2
      parsedRR.addresses[0].address == multiAddresses[0]
      parsedRR.addresses[1].address == multiAddresses[1]

  test "Interop decode":
    let
      # from https://github.com/libp2p/go-libp2p-core/blob/b18a4c9c5629870bde2cd85ab3b87a507600d411/peer/record_test.go#L33
      # (with only 2 addresses)
      inputData = "0a2600240801122011bba3ed1721948cefb4e50b0a0bb5cad8a6b52dc7b1a40f4f6652105c91e2c4109bf59d8dd99d8ddb161a0a0a0804010203040600001a0a0a080401020304060001".hexToSeqByte()
      decodedRecord = PeerRecord.decode(inputData).tryGet()

    check:
      $decodedRecord.peerId == "12D3KooWB1b3qZxWJanuhtseF3DmPggHCtG36KZ9ixkqHtdKH9fh"
      decodedRecord.seqNo == uint64 1636553709551319707
      decodedRecord.addresses.len == 2
      $decodedRecord.addresses[0].address == "/ip4/1.2.3.4/tcp/0"
      $decodedRecord.addresses[1].address == "/ip4/1.2.3.4/tcp/1"

