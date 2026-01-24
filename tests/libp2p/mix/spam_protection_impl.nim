# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import results
import ../../../libp2p/protocols/mix/spam_protection

# Custom spam protection implementations for testing integration scenarios

const
  PoWProofSize = 8 # Size of nonce in bytes
  RateLimitProofSize = 4 # Size of timestamp in bytes
  MaxPoWIterations = 100000 # Maximum iterations for PoW proof generation

type
  # Simple Proof-of-Work implementation for testing
  PoWSpamProtection* = ref object of SpamProtection
    difficulty*: int
    verificationCount*: int # Track how many verifications were performed

proc newPoWSpamProtection*(difficulty: int = 2): PoWSpamProtection =
  PoWSpamProtection(
    proofSize: PoWProofSize, difficulty: difficulty, verificationCount: 0
  )

method generateProof*(
    self: PoWSpamProtection, bindingData: seq[byte]
): Result[seq[byte], string] =
  # Simplified PoW: find nonce where last byte of hash has 'difficulty' leading zeros
  let bindingBytes = bindingData
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
    nonce += 1

  err("Failed to find valid nonce")

method verifyProof*(
    self: PoWSpamProtection, encodedProofData: seq[byte], bindingData: seq[byte]
): Result[bool, string] =
  self.verificationCount += 1

  let proofBytes = encodedProofData
  let bindingBytes = bindingData

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
  RateLimitSpamProtection* = ref object of SpamProtection
    maxPacketsPerWindow*: int
    packetCount*: int
    lastResetTime*: int

proc newRateLimitSpamProtection*(
    maxPacketsPerWindow: int = 10
): RateLimitSpamProtection =
  RateLimitSpamProtection(
    proofSize: RateLimitProofSize,
    maxPacketsPerWindow: maxPacketsPerWindow,
    packetCount: 0,
    lastResetTime: 0,
  )

method generateProof*(
    self: RateLimitSpamProtection, bindingData: seq[byte]
): Result[seq[byte], string] =
  # Generate timestamp-based proof
  let timestamp = 12345 # Simplified timestamp
  ok(
    @[
      byte(timestamp shr 24),
      byte(timestamp shr 16),
      byte(timestamp shr 8),
      byte(timestamp),
    ]
  )

method verifyProof*(
    self: RateLimitSpamProtection, encodedProofData: seq[byte], bindingData: seq[byte]
): Result[bool, string] =
  let proofBytes = encodedProofData
  if proofBytes.len != 4:
    return ok(false)

  # Check rate limit
  self.packetCount += 1
  if self.packetCount > self.maxPacketsPerWindow:
    return ok(false)

  ok(true)
