# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module defines the spam protection interface for the Mix Protocol
## as specified in section 9.6 of the MIX protocol specification.
##
## Uses per-hop proof generation where each node generates fresh proofs for the next hop.

import results

type
  EncodedProofData* = distinct seq[byte]
    ## Serialized bytes containing proof and verification metadata.
    ## Opaque to the Mix Protocol layer.

  BindingData* = distinct seq[byte]
    ## Packet-specific data against which proof is bound and verified.
    ## For sender-generated: decrypted payload the hop will see
    ## For per-hop: complete outgoing Sphinx packet state

  SpamProtection* = ref object of RootObj
    ## Abstract interface that spam protection mechanisms must implement
    ## to integrate with the Mix Protocol.
    ## Uses per-hop proof generation architecture.
    proofSize*: int

# Allow conversion to/from seq[byte] for the distinct types
converter toSeqByte*(data: EncodedProofData): seq[byte] =
  seq[byte](data)

converter toEncodedProofData*(data: seq[byte]): EncodedProofData =
  EncodedProofData(data)

converter toSeqByteBinding*(data: BindingData): seq[byte] =
  seq[byte](data)

converter toBindingData*(data: seq[byte]): BindingData =
  BindingData(data)

method generateProof*(
    self: SpamProtection, bindingData: BindingData
): Result[EncodedProofData, string] {.base, gcsafe, raises: [].} =
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
    self: SpamProtection, encodedProofData: EncodedProofData, bindingData: BindingData
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
): Result[(seq[byte], EncodedProofData), string] =
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
    return ok((packetWithProof, EncodedProofData(newSeq[byte](0))))

  if packetWithProof.len < proofSize:
    return err("Packet too small to contain proof")

  # Copy only the small proof data from the end using slice
  let proofStartIdx = packetWithProof.len - proofSize
  let proofBytes = packetWithProof[proofStartIdx ..< packetWithProof.len]

  # Truncate the packet in-place to remove proof (zero-copy for Sphinx packet)
  packetWithProof.setLen(proofStartIdx)

  ok((packetWithProof, EncodedProofData(proofBytes)))

proc appendProofToPacket*(
    sphinxPacket: seq[byte], proof: EncodedProofData
): Result[seq[byte], string] =
  ## Append spam protection proof to end of Sphinx packet.
  ## This is called when generating fresh proof for next hop.
  ##
  ## Returns: Complete packet with proof appended
  if proof.len == 0: # note override len
    return ok(sphinxPacket)

  let proofBytes: seq[byte] = proof # note better just cast if possible
  ok(sphinxPacket & proofBytes)
