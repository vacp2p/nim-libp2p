# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import unittest2
import results
import ../../../libp2p/protocols/mix/spam_protection

# Custom spam protection implementations for testing integration scenarios

const
  PoWProofSize = 8 # Size of nonce in bytes
  RateLimitProofSize = 4 # Size of timestamp in bytes
  MaxPoWIterations = 100000 # Maximum iterations for PoW proof generation

type
  # Simple Proof-of-Work implementation for testing
  TestPoWSpamProtection = ref object of SpamProtectionInterface
    difficulty: int
    fixedProofSize: int
    verificationCount: int # Track how many verifications were performed

proc newTestPoWSpamProtection*(
    difficulty: int = 2, architecture: SpamProtectionArchitecture
): TestPoWSpamProtection =
  TestPoWSpamProtection(
    fixedProofSize: PoWProofSize,
    architecture: architecture,
    difficulty: difficulty,
    verificationCount: 0,
  )

method proofSize*(self: TestPoWSpamProtection): int =
  self.fixedProofSize

method generateProof*(
    self: TestPoWSpamProtection, bindingData: BindingData
): Result[EncodedProofData, string] =
  # Simplified PoW: find nonce where last byte of hash has 'difficulty' leading zeros
  let bindingBytes: seq[byte] = bindingData
  var nonce: uint64 = 0
  while nonce < MaxPoWIterations:
    var testData =
      bindingBytes &
      @[
        byte(nonce shr 56),
        byte(nonce shr 48),
        byte(nonce shr 40),
        byte(nonce shr 32),
        byte(nonce shr 24),
        byte(nonce shr 16),
        byte(nonce shr 8),
        byte(nonce),
      ]
    # Simple hash: XOR all bytes
    var hash: byte = 0
    for b in testData:
      hash = hash xor b

    # Check if hash meets difficulty (leading zeros in binary representation)
    if (hash and byte((1 shl self.difficulty) - 1)) == 0:
      return ok(
        EncodedProofData(
          @[
            byte(nonce shr 56),
            byte(nonce shr 48),
            byte(nonce shr 40),
            byte(nonce shr 32),
            byte(nonce shr 24),
            byte(nonce shr 16),
            byte(nonce shr 8),
            byte(nonce),
          ]
        )
      )
    nonce += 1

  err("Failed to find valid nonce")

method verifyProof*(
    self: TestPoWSpamProtection,
    encodedProofData: EncodedProofData,
    bindingData: BindingData,
): Result[bool, string] =
  self.verificationCount += 1

  let proofBytes: seq[byte] = encodedProofData
  let bindingBytes: seq[byte] = bindingData

  if proofBytes.len != 8:
    return ok(false)

  # Reconstruct the test data with the provided nonce
  var testData = bindingBytes & proofBytes

  # Recompute hash
  var hash: byte = 0
  for b in testData:
    hash = hash xor b

  # Verify difficulty requirement
  ok((hash and byte((1 shl self.difficulty) - 1)) == 0)

type
  # Rate limiting implementation for testing per-hop generation
  TestRateLimitSpamProtection = ref object of SpamProtectionInterface
    maxPacketsPerWindow: int
    fixedProofSize: int
    packetCount: int
    lastResetTime: int

proc newTestRateLimitSpamProtection*(
    maxPacketsPerWindow: int = 10, architecture: SpamProtectionArchitecture
): TestRateLimitSpamProtection =
  TestRateLimitSpamProtection(
    fixedProofSize: RateLimitProofSize,
    architecture: architecture,
    maxPacketsPerWindow: maxPacketsPerWindow,
    packetCount: 0,
    lastResetTime: 0,
  )

method proofSize*(self: TestRateLimitSpamProtection): int =
  self.fixedProofSize

method generateProof*(
    self: TestRateLimitSpamProtection, bindingData: BindingData
): Result[EncodedProofData, string] =
  # Generate timestamp-based proof
  let timestamp = 12345 # Simplified timestamp
  ok(
    EncodedProofData(
      @[
        byte(timestamp shr 24),
        byte(timestamp shr 16),
        byte(timestamp shr 8),
        byte(timestamp),
      ]
    )
  )

method verifyProof*(
    self: TestRateLimitSpamProtection,
    encodedProofData: EncodedProofData,
    bindingData: BindingData,
): Result[bool, string] =
  let proofBytes: seq[byte] = encodedProofData
  if proofBytes.len != 4:
    return ok(false)

  # Check rate limit
  self.packetCount += 1
  if self.packetCount > self.maxPacketsPerWindow:
    return ok(false)

  ok(true)

suite "Spam Protection - Per Hop Proof Generation":
  test "Proof generation and verification cycle":
    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    # Simulate node generating proof for packet
    let packetData: BindingData = @[1.byte, 2, 3, 4, 5]
    let proofResult = spamProtection.generateProof(packetData)

    check proofResult.isOk()
    let proof = proofResult.get()
    check proof.len == 8

    # Simulate next node verifying proof with same packet
    let verifyResult = spamProtection.verifyProof(proof, packetData)

    check verifyResult.isOk()
    check verifyResult.get() == true
    check spamProtection.verificationCount == 1

  test "Proof verification fails with wrong binding data":
    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    let originalPacket: BindingData = @[1.byte, 2, 3, 4, 5]
    let proofResult = spamProtection.generateProof(originalPacket)

    check proofResult.isOk()
    let proof = proofResult.get()

    # Try to verify with different packet
    let differentPacket: BindingData = @[1.byte, 2, 3, 4, 6]
    let verifyResult = spamProtection.verifyProof(proof, differentPacket)

    check verifyResult.isOk()
    check verifyResult.get() == false

  test "Proof verification rejects malformed proofs":
    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    let packetData: BindingData = @[1.byte, 2, 3, 4, 5]

    # Malformed proof (wrong size)
    let malformedProof: EncodedProofData = @[1.byte, 2, 3]
    let verifyResult = spamProtection.verifyProof(malformedProof, packetData)

    check verifyResult.isOk()
    check verifyResult.get() == false

  test "Multiple proofs can be generated for different packets":
    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    let packet1: BindingData = @[1.byte, 2, 3]
    let packet2: BindingData = @[4.byte, 5, 6]

    let proof1 = spamProtection.generateProof(packet1).get()
    let proof2 = spamProtection.generateProof(packet2).get()

    # Each proof should verify with its corresponding packet
    check spamProtection.verifyProof(proof1, packet1).get() == true
    check spamProtection.verifyProof(proof2, packet2).get() == true

    # But not with the other packet
    check spamProtection.verifyProof(proof1, packet2).get() == false
    check spamProtection.verifyProof(proof2, packet1).get() == false

suite "Spam Protection - Per Hop Generation":
  test "Rate limiting allows packets within limit":
    let spamProtection =
      newTestRateLimitSpamProtection(5, SpamProtectionArchitecture.PerHopGeneration)

    let packetData: BindingData = @[1.byte, 2, 3, 4]

    # Generate and verify 5 packets (within limit)
    for i in 0 ..< 5:
      let proof = spamProtection.generateProof(packetData).get()
      let valid = spamProtection.verifyProof(proof, packetData).get()
      check valid == true

  test "Rate limiting blocks packets exceeding limit":
    let spamProtection =
      newTestRateLimitSpamProtection(3, SpamProtectionArchitecture.PerHopGeneration)

    let packetData: BindingData = @[1.byte, 2, 3, 4]

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
    let spamProtection =
      newTestRateLimitSpamProtection(10, SpamProtectionArchitecture.PerHopGeneration)

    let packet1: BindingData = @[1.byte, 2, 3]
    let packet2: BindingData = @[4.byte, 5, 6]

    # Generate fresh proofs for each packet
    let proof1 = spamProtection.generateProof(packet1).get()
    let proof2 = spamProtection.generateProof(packet2).get()

    # Both should verify successfully (rate limit not exceeded)
    check spamProtection.verifyProof(proof1, packet1).get() == true
    check spamProtection.verifyProof(proof2, packet2).get() == true

suite "Spam Protection - Packet Integration":
  test "Proof can be appended and extracted from packet":
    let sphinxPacket = @[1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let proof = EncodedProofData(@[77.byte, 88, 99, 11, 22, 33, 44, 55])

    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    # Append proof to packet
    let appendResult = appendProofToPacket(sphinxPacket, proof)
    check appendResult.isOk()
    var packetWithProof = appendResult.get()

    # Extract proof from packet (mutates packetWithProof)
    let extractResult = extractProofFromPacket(packetWithProof, spamProtection)
    check extractResult.isOk()
    let (extractedSphinx, extractedProof) = extractResult.get()
    let originalProof: seq[byte] = proof
    check extractedProof == originalProof
    check extractedSphinx == sphinxPacket

  test "Packet structure maintained after proof append/extract":
    let sphinxPacket = @[1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    let proof = EncodedProofData(@[100.byte, 101, 102, 103, 104, 105, 106, 107])

    let spamProtection =
      newTestPoWSpamProtection(2, SpamProtectionArchitecture.PerHopGeneration)

    let appendResult = appendProofToPacket(sphinxPacket, proof)
    check appendResult.isOk()
    let packetWithProof = appendResult.get()

    # Check packet structure: [sphinx][proof]
    check packetWithProof.len == sphinxPacket.len + 8
    check packetWithProof[0 ..< sphinxPacket.len] == sphinxPacket
    let proofBytes: seq[byte] = proof
    check packetWithProof[^8 ..^ 1] == proofBytes

suite "Spam Protection - Disabled Mode":
  test "nil spam protection means disabled":
    # When spamProtection is nil, spam protection is disabled
    # This is tested implicitly in integration tests where spamProtection=nil by default
    check true # Placeholder test to keep suite structure
