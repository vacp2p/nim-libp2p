# Spam Protection Interface

A pluggable interface for integrating spam protection mechanisms into the Mix protocol, as specified in [section 9.6 of the MIX specification](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md#96-spam-protection-interface).

## Architecture

Currently, only **Per-Hop Generation** is implemented, where each mix node generates fresh proofs for the next hop.

## Packet Structure

Proofs are appended after the Sphinx packet:

```
Wire Format: [Sphinx Packet: 4608 bytes][Proof: proofSize bytes]
```

## Usage

```nim
import libp2p/protocols/mix

type
  MySpamProtection = ref object of SpamProtectionInterface
    # Your mechanism-specific state

proc newMySpamProtection*(
    architecture: SpamProtectionArchitecture
): MySpamProtection =
  MySpamProtection(
    architecture: architecture
  )

method proofSize*(self: MySpamProtection): int =
  32  # Your proof size

method generateProof*(
    self: MySpamProtection,
    bindingData: BindingData
): Result[EncodedProofData, string] =
  # Your proof generation logic
  ok(myProof)

method verifyProof*(
    self: MySpamProtection,
    encodedProofData: EncodedProofData,
    bindingData: BindingData,
): Result[bool, string] =
  # Your proof verification logic
  ok(isValid)

# Configure spam protection
let config = initSpamProtectionConfig(
  architecture = SpamProtectionArchitecture.PerHopGeneration
)

# Create spam protection instance
let spamProtection = newMySpamProtection(config.architecture)

# Create MixProtocol with spam protection
let mixProto = MixProtocol.new(
  mixNodeInfo,
  pubNodeInfo,
  switch,
  spamProtection = spamProtection,
  spamProtectionConfig = config
)
```

## Disabling Spam Protection

To disable spam protection, simply pass `nil` as the `spamProtection` parameter when initializing MixProtocol:

```nim
# Create MixProtocol without spam protection (disabled by default)
let mixProto = MixProtocol.new(
  mixNodeInfo,
  pubNodeInfo,
  switch
  # spamProtection = nil (default)
)
```

When spam protection is disabled (nil):
- No proofs are generated or verified
- Zero computational overhead
- Wire packet size equals Sphinx packet size (4608 bytes)

## Example Implementations

See [test_spam_protection.nim](../../tests/libp2p/mix/test_spam_protection.nim) for example implementations:

- **Proof-of-Work**: Requires computational work to generate proofs
- **Rate Limiting**: Tracks and limits packet rates per node

## Further Reading

For detailed specification and security considerations, see:
- [MIX Protocol Specification](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md)
- [Spam Protection Interface (Section 9.6)](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md#96-spam-protection-interface)
