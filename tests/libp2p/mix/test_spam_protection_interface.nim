# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import unittest2
import results
import ../../../libp2p/protocols/mix/spam_protection
import ./spam_protection_impl

const testPacketData = @[1.byte, 2, 3, 4, 5]

suite "Spam Protection - Per Hop Proof Generation":
  test "Proof generation and verification cycle":
    let spamProtection = newPoWSpamProtection(2)

    # Simulate node generating proof for packet
    let packetData = testPacketData
    let proof = spamProtection.generateProof(packetData).get()
    check proof.len == 8

    # Simulate next node verifying proof with same packet
    let verifyResult = spamProtection.verifyProof(proof, packetData)

    check verifyResult.isOk()
    check verifyResult.get() == true
    check spamProtection.verificationCount == 1

  test "Proof verification fails with wrong binding data":
    let spamProtection = newPoWSpamProtection(2)

    let originalPacket = testPacketData
    let proof = spamProtection.generateProof(originalPacket).get()

    # Try to verify with different packet
    let differentPacket = @[1.byte, 2, 3, 4, 6]
    let verifyResult = spamProtection.verifyProof(proof, differentPacket)

    check verifyResult.isOk()
    check verifyResult.get() == false

  test "Proof verification rejects malformed proofs":
    let spamProtection = newPoWSpamProtection(2)

    let packetData = testPacketData

    # Malformed proof (wrong size)
    let malformedProof = @[1.byte, 2, 3]
    let verifyResult = spamProtection.verifyProof(malformedProof, packetData)

    check verifyResult.isOk()
    check verifyResult.get() == false

  test "Multiple proofs can be generated for different packets":
    let spamProtection = newPoWSpamProtection(2)

    let packet1 = testPacketData
    let packet2 = @[4.byte, 5, 6]

    let proof1 = spamProtection.generateProof(packet1).get()
    let proof2 = spamProtection.generateProof(packet2).get()

    # Each proof should verify with its corresponding packet
    check spamProtection.verifyProof(proof1, packet1).get() == true
    check spamProtection.verifyProof(proof2, packet2).get() == true

    # But not with the other packet
    check spamProtection.verifyProof(proof1, packet2).get() == false
    check spamProtection.verifyProof(proof2, packet1).get() == false

  test "Rate limiting blocks packets exceeding limit":
    let spamProtection = newRateLimitSpamProtection(3)

    let packetData = testPacketData

    # First 3 packets should be accepted
    for i in 0 ..< 3:
      let proof = spamProtection.generateProof(packetData).get()
      let valid = spamProtection.verifyProof(proof, packetData).get()
      check valid == true

    # 4th packet should be rejected
    let proof4 = spamProtection.generateProof(packetData).get()
    let valid4 = spamProtection.verifyProof(proof4, packetData).get()
    check valid4 == false

  test "Per-hop proofs are independently generated":
    let spamProtection = newTestRateLimitSpamProtection(10)

    let packet1 = testPacketData
    let packet2 = @[4.byte, 5, 6]

    # Generate fresh proofs for each packet
    let proof1 = spamProtection.generateProof(packet1).get()
    let proof2 = spamProtection.generateProof(packet2).get()

    # Both should verify successfully (rate limit not exceeded)
    check spamProtection.verifyProof(proof1, packet1).get() == true
    check spamProtection.verifyProof(proof2, packet2).get() == true

suite "Spam Protection - Packet Integration":
  test "Proof can be appended and extracted from packet":
    let sphinxPacket = @[1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let proof = @[77.byte, 88, 99, 11, 22, 33, 44, 55]

    let spamProtection = newPoWSpamProtection(2)

    # Append proof to packet
    var packetWithProof = appendProofToPacket(sphinxPacket, proof).get()

    # Extract proof from packet (mutates packetWithProof)
    let (extractedSphinx, extractedProof) =
      extractProofFromPacket(packetWithProof, spamProtection).get()
    check extractedProof == proof
    check extractedSphinx == sphinxPacket

  test "Packet structure maintained after proof append/extract":
    let sphinxPacket = @[1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    let proof = @[100.byte, 101, 102, 103, 104, 105, 106, 107]

    let spamProtection = newPoWSpamProtection(2)

    let packetWithProof = appendProofToPacket(sphinxPacket, proof).get()

    # Check packet structure: [sphinx][proof]
    check packetWithProof.len == sphinxPacket.len + 8
    check packetWithProof[0 ..< sphinxPacket.len] == sphinxPacket
    check packetWithProof[^8 ..^ 1] == proof

suite "Spam Protection - Edge Cases":
  test "extractProofFromPacket fails when packet too small":
    let spamProtection = newTestPoWSpamProtection(2)

    # Create a packet smaller than proof size (8 bytes)
    var tinyPacket = @[1.byte, 2, 3] # Only 3 bytes, but proof needs 8

    let result = extractProofFromPacket(tinyPacket, spamProtection)
    check result.isErr()
    check result.error() == "Packet too small to contain proof"

  test "appendProofToPacket with empty proof returns original packet":
    let sphinxPacket = testPacketData
    let emptyProof = newSeq[byte](0)

    check appendProofToPacket(sphinxPacket, emptyProof).get() == sphinxPacket

  test "extractProofFromPacket with zero proof size returns packet unchanged":
    # Create a spam protection with zero proof size
    let spamProtection = newRateLimitSpamProtection(10)
    spamProtection.proofSize = 0

    var packet: seq[byte] = testPacketData
    let originalPacket = packet

    let (extractedPacket, extractedProof) =
      extractProofFromPacket(packet, spamProtection).get()
    check extractedPacket == originalPacket
    check extractedProof.len == 0
