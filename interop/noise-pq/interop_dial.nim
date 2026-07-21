# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Standalone interop dialer for NoiseHFS
## (`Noise_XXhfs_25519+ML-KEM-768_ChaChaPoly_SHA256`).
##
## Dials a peer speaking the same protocol and completes a real handshake
## over TCP, independent of the rest of the nim-libp2p test suite. Used to
## verify wire-format compatibility against other language implementations
## of the same profile (see NOISE_HFS_SPEC.md).
##
## Usage:
##   nim c -r interop_dial.nim [port]   (default 9998)
##
## Verified against py-libp2p's `scripts/interop_listen_mlkem768.py`
## (libp2p/py-libp2p, branch feat/pqc-noise-xxhfs) on 2026-07-11: dial ->
## handshake -> peer authentication all completed successfully on both
## sides, with no changes needed to either implementation's wire format.

import std/[os, strutils]
import chronos
import
  ../../libp2p/[
    stream/connection,
    transports/transport,
    transports/tcptransport,
    multiaddress,
    peerinfo,
    crypto/crypto,
    crypto/rng,
    protocols/secure/noisehfs,
    upgrademngrs/upgrade,
  ]

proc main() {.async.} =
  let port =
    if paramCount() >= 1: parseInt(paramStr(1))
    else: 9998

  let
    rng = newRng()
    # Ed25519, not the crypto module's default ECDSA: several peer libp2p
    # implementations (e.g. py-libp2p as of this writing) only implement
    # protobuf key-type deserializers for a subset of libp2p's key types.
    privKey = PrivateKey.random(Ed25519, rng).get()
    noiseHFS = NoiseHFS.new(rng, privKey)
    transport = TcpTransport.new(upgrade = Upgrade())
    remoteMa = MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).get()

  echo "DIALING port ", port
  let conn = await transport.dial(remoteMa)
  let sconn = await noiseHFS.secure(conn, Opt.none(PeerId))

  echo "HANDSHAKE_OK remotePeer=", $sconn.peerId
  await sconn.close()
  await conn.close()
  await transport.stop()

waitFor(main())
