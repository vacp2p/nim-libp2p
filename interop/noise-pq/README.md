# NoiseHFS interop scripts

Standalone dial/listen scripts for `Noise_XXhfs_25519+ML-KEM-768_ChaChaPoly_SHA256`
(protocol id `/noise-mlkem768-hfs/0.1.0`), independent of the rest of the
nim-libp2p test suite. See `../../libp2p/protocols/secure/NOISE_HFS_SPEC.md`
for the wire format.

## Usage

```bash
nim c -r interop_listen.nim [port]   # accepts one connection, then exits
nim c -r interop_dial.nim [port]     # dials 127.0.0.1:port
```

Both print `HANDSHAKE_OK remotePeer=<peer id>` on success.

## Verified interop

**nim-libp2p <-> py-libp2p, 2026-07-11**

`interop_dial.nim` against py-libp2p's `scripts/interop_listen_mlkem768.py`
(libp2p/py-libp2p, branch `feat/pqc-noise-xxhfs`), both on the raw
ML-KEM-768 (not X-Wing) revision:

```
# py-libp2p side
READY 9999
Connection from 127.0.0.1:56421
PEER 12D3KooWLitocTge1Lm2TmS3THHfrMWfV3d6UJZpPZNweL3c6CFD

# nim-libp2p side
DIALING port 9999
HANDSHAKE_OK remotePeer=12D3KooWJGqi39m6ykyVhs8K1c1z8eeb4nFEqVxHLPopHdm8rV9h
```

Both sides completed the full three-message XXhfs handshake - X25519 DH,
ML-KEM-768 encapsulate/decapsulate, ChaCha20-Poly1305 AEAD, and Ed25519 peer
identity signature verification - with no changes needed to either
implementation's wire format. The differing peer ids above are expected:
each side reports the *other* side's freshly-generated identity, not its
own.

Note: the identity key used here is Ed25519, not the crypto module's
default ECDSA - as of this writing, py-libp2p's protobuf key-type
deserializer only implements Secp256k1, RSA, and Ed25519, so an ECDSA
identity key fails at the peer-identity-verification step with an unrelated
`MissingDeserializerError`, after the actual Noise/KEM handshake has already
succeeded. That's a py-libp2p key-type support gap, not a NoiseHFS wire
compatibility issue.

## Not yet run

- **Rust** (royzah/rust-libp2p PR #1): not attempted here - would require a
  from-scratch rust-libp2p workspace build, which is out of scope for this
  session. The crate should be a straightforward target for the same
  dial/listen pattern once built.
- **JavaScript** (ChainSafe/js-libp2p-noise PR #665): not attempted here.
