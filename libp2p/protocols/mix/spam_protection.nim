# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

## This module defines the spam protection interface for the Mix Protocol
## as specified in section 9.6 of the MIX protocol specification.
##
## Uses per-hop proof generation where each node generates fresh proofs for the next hop.

import results

type SpamProtection* = ref object of RootObj
  ## Abstract interface that spam protection mechanisms must implement
  ## to integrate with the Mix Protocol.
  ## Uses per-hop proof generation architecture.
  proofSize*: int

method generateProof*(
    self: SpamProtection, bindingData: seq[byte]
): Result[seq[byte], string] {.base, gcsafe, raises: [].} =
  ## Generate a spam protection proof bound to specific packet data.
  ##
  ## Parameters:
  ##   bindingData: For sender-generated proofs, this is the decrypted payload
  ##                the hop will see; for per-hop generation, the complete
  ##                outgoing Sphinx packet state.
  ##
  ## Returns:
  ##   Serialized bytes containing proof and verification metadata
  ##   (opaque to Mix Protocol layer).
  ##
  ## Requirements:
  ##   - Must produce output with length == self.proofSize
  ##   - Mechanism manages its own runtime state independently
  ##
  ## Note: This base implementation should be overridden by concrete types.
  raiseAssert "generateProof must be implemented by concrete spam protection types"

method verifyProof*(
    self: SpamProtection, encodedProofData: seq[byte], bindingData: seq[byte]
): Result[bool, string] {.base, gcsafe, raises: [].} =
  ## Validate that a proof is correct and properly bound to packet data.
  ##
  ## Parameters:
  ##   encodedProofData: Extracted from routing block (sender approach)
  ##                     or header field (per-hop approach)
  ##   bindingData: The packet-specific data against which proof is verified
  ##
  ## Returns:
  ##   Boolean indicating validity wrapped in Result.
  ##
  ## Requirements:
  ##   - Must handle malformed inputs gracefully, returning false
  ##   - Must atomically update internal state on successful verification
  ##   - Must manage state cleanup independently
  ##
  ## Note: This base implementation should be overridden by concrete types.
  raiseAssert "verifyProof must be implemented by concrete spam protection types"

# Note: To disable spam protection, pass nil as the spamProtection parameter
# when initializing MixProtocol. No no-op implementation is needed.

# Integration helpers for per-hop spam protection
#
# Packet Structure (on wire): [Sphinx Packet: 4608 bytes][Sigma: proofSize bytes]
#
# The sigma (σ) field is appended after the Sphinx packet and contains the
# spam protection proof. This approach:
# - Keeps Sphinx packet structure unchanged (α|β|γ|δ)
# - Allows simple append/strip operations at each hop
# - Each hop: strips old proof, processes Sphinx, appends fresh proof
# - Total wire size: 4608 + proofSize bytes

proc extractProofFromPacket*(
    packetWithProof: var seq[byte], spamProtection: SpamProtection
): Result[(seq[byte], seq[byte]), string] =
  ## Extract spam protection proof from end of packet and return both
  ## the Sphinx packet (without proof) and the extracted proof.
  ## This is called by intermediary nodes before Sphinx decryption.
  ##
  ## Zero-copy optimization: Takes ownership of the input packet via `var`,
  ## truncates it to remove the proof, and only copies the small proof data.
  ## This avoids copying the large (4608 byte) Sphinx packet.
  ##
  ## Returns: (sphinxPacket, proof)
  let proofSize = spamProtection.proofSize
  if proofSize == 0:
    return ok((packetWithProof, newSeq[byte](0)))

  if packetWithProof.len < proofSize:
    return err("Packet too small to contain proof")

  # Copy only the small proof data from the end using slice
  let proofStartIdx = packetWithProof.len - proofSize
  let proofBytes = packetWithProof[proofStartIdx ..< packetWithProof.len]

  # Truncate the packet in-place to remove proof (zero-copy for Sphinx packet)
  packetWithProof.setLen(proofStartIdx)

  ok((packetWithProof, proofBytes))

proc appendProofToPacket*(
    sphinxPacket: seq[byte], proof: seq[byte]
): Result[seq[byte], string] =
  ## Append spam protection proof to end of Sphinx packet.
  ## This is called when generating fresh proof for next hop.
  ##
  ## Returns: Complete packet with proof appended
  if proof.len == 0:
    return ok(sphinxPacket)

  ok(sphinxPacket & proof)
