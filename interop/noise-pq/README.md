# NoiseHFS interop scripts

Standalone dial/listen scripts for `Noise_XXhfs_25519+ML-KEM-768_ChaChaPoly_SHA256`
(protocol id `/noise-mlkem768-hfs/0.1.0`), independent of the rest of the
nim-libp2p test suite. See `../../libp2p/protocols/secure/NOISE_HFS_SPEC.md`
for the wire format.

## Usage

```bash
nim c -r interop_listen.nim [port]           # accepts one connection, then exits
nim c -r interop_dial.nim [port] [--chat]    # dials 127.0.0.1:port
```

Both print `HANDSHAKE_OK remotePeer=<peer id>` on success.

With `--chat` the dialer also reads one post-handshake message and replies with
`hello from Nim`. That matters because completing the handshake only proves the
two sides agreed on the handshake hash and the KEM shared secret - it says
nothing about whether the transport cipher states came out of `split()` with the
same orientation. A swapped `cs1`/`cs2` still prints `HANDSHAKE_OK` and only
fails on the first real data frame.

`interop_all.sh` runs every pairing below against local checkouts of the other
implementations:

```bash
JS_NOISE_DIR=../../../js-libp2p-noise RUST_LIBP2P_DIR=../../../rust-libp2p   bash interop_all.sh
```

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

**nim-libp2p <-> js-libp2p-noise, 2026-09-05**

Both roles, against ChainSafe/js-libp2p-noise PR #665 (branch
`feat/pqc-xxhfs-noise`) on Node.js v22.17.1.

nim-libp2p listening, `scripts/noise-hfs-dial.mjs` dialling:

```
# nim-libp2p side                      # js-libp2p-noise side
READY 9101                             PEER 12D3KooWJdMEZoTchgFtZDD1FYUEqRHtpas54b4fBShsrqPidVyb
HANDSHAKE_OK remotePeer=12D3KooWN1LK85XfPFGzKq3gjTnm12e4tZn84GeSkNpQf6Fve4hS
```

js-libp2p-noise listening, `interop_dial --chat` dialling, with a message
exchanged in each direction after the handshake:

```
# js-libp2p-noise side                        # nim-libp2p side
Listener peer ID: 12D3KooWEBXx...uTxUxX2x     DIALING port 8000
Handshake complete! Remote peer: 12D3KooW...  HANDSHAKE_OK remotePeer=12D3KooWEBXx...uTxUxX2x
Sent: "hello from JS"                         RECV hello from JS
Received: "hello from Nim"                    SENT hello from Nim
INTEROP SUCCESS
```

Note that the peer id nim-libp2p reports here is exactly the id the JS listener
printed for itself, so the Ed25519 identity signature over the handshake hash
verified - both sides computed the same `h`. The message exchange covers both
transport keys: nim decrypting the JS frame exercises one `split()` output, JS
decrypting the nim frame exercises the other.

**nim-libp2p <-> rust-libp2p, 2026-09-05**

Against royzah/rust-libp2p PR #1 (branch `feat/noise-mlkem-hfs`), built with
`cargo build -p libp2p-noise --example noise_hfs_listener --features mlkem-hfs`:

```
# rust-libp2p side                     # nim-libp2p side
READY 9103                             DIALING port 9103
connection from 127.0.0.1:62444        HANDSHAKE_OK remotePeer=12D3KooWFXYW...Dd8atwd
PEER 12D3KooWHQEvXV28iyrSzHzwbYmLcRpk2zBHyk22ayGLxe91BdB9
```

Only this direction is covered: rust-libp2p ships a listener example but no
dialer, so nim-libp2p is always the initiator in this pair.

## Coverage

With the two runs above, all six pairings across the four implementations of
this profile - TypeScript, Python, Rust and Nim - have now completed a live
handshake:

| | TypeScript | Python | Rust | Nim |
|---|---|---|---|---|
| **TypeScript** | - | 2026-06-24 | 2026-06-24 | 2026-09-05 |
| **Python** | 2026-06-24 | - | 2026-06-24 | 2026-07-11 |
| **Rust** | 2026-06-24 | 2026-06-24 | - | 2026-09-05 |
| **Nim** | 2026-09-05 | 2026-07-11 | 2026-09-05 | - |
