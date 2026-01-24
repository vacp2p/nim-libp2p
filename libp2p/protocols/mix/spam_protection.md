# Spam Protection Interface

A pluggable interface for integrating spam protection mechanisms into the Mix protocol, as specified in [section 9.6 of the MIX specification](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md#96-spam-protection-interface).

## Architecture

Currently, only **Per-Hop Generation** is implemented, where each mix node generates fresh proofs for the next hop.

## Packet Structure

Proofs are appended after the Sphinx packet:

```
Wire Format: [Sphinx Packet: 4608 bytes][Proof: proofSize bytes]
```

## Disabling Spam Protection

To disable spam protection, simply pass `nil` as the `spamProtection` parameter when initializing MixProtocol.

When spam protection is disabled (nil):

- No proofs are generated or verified
- Wire packet size equals Sphinx packet size (4608 bytes)

## Example Implementations

See [test_spam_protection_interface.nim](../../tests/libp2p/mix/test_spam_protection_interface.nim) for example implementations:

- **Proof-of-Work**: Requires computational work to generate proofs
- **Rate Limiting**: Tracks and limits packet rates per node

## Further Reading

For detailed specification and security considerations, see:

- [MIX Protocol Specification](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md)
- [Spam Protection Interface (Section 9.6)](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/mix.md#96-spam-protection-interface)
