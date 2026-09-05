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
##   nim c -r interop_dial.nim [port] [--chat]   (default port 9998)
##
## With `--chat`, the dialer also reads one post-handshake message and replies
## with "hello from Nim", exercising the transport cipher states rather than
## just the handshake. Use it against listeners that expect a reply (e.g.
## js-libp2p-noise's scripts/node-listener.mjs).
##
## Verified against py-libp2p's `scripts/interop_listen_mlkem768.py`
## (libp2p/py-libp2p, branch feat/pqc-noise-xxhfs) on 2026-07-11: dial ->
## handshake -> peer authentication all completed successfully on both
## sides, with no changes needed to either implementation's wire format.

import std/[os, strutils]
import chronos
import stew/byteutils
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

const
  # How long the --chat dialer waits for the peer to close after it replies.
  PeerCloseTimeout = 5.seconds

proc main() {.async.} =
  var
    port = 9998
    chat = false

  # Positional port, plus an optional `--chat` flag. Without --chat the dialer
  # closes as soon as the handshake succeeds, which is what listeners that only
  # verify the handshake (rust-libp2p's noise_hfs_listener, py-libp2p's
  # interop_listen_mlkem768.py) expect.
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg == "--chat":
      chat = true
    elif arg.len > 0 and arg.allCharsInSet(Digits):
      port = parseInt(arg)
    else:
      quit("usage: interop_dial [port] [--chat]", 1)

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

  # Optional post-handshake exchange. Completing the handshake only proves both
  # sides agreed on the handshake hash and the KEM shared secret; it does not
  # prove the two transport cipher states came out of split() with the same
  # key/nonce orientation. A swapped cs1/cs2 still yields HANDSHAKE_OK and only
  # fails here, on the first real data frame.
  if chat:
    let incoming = await sconn.readMessage()
    echo "RECV ", string.fromBytes(incoming).strip()
    await sconn.write("hello from Nim" & $chr(10))
    echo "SENT hello from Nim"

    # Wait for the peer to close instead of tearing the connection down right
    # away: closing abortively here can discard the frame we just wrote before
    # the peer has read it, which shows up on the other side as ECONNRESET.
    # The expected outcome is an EOF once the peer closes its end.
    try:
      discard await sconn.readMessage().wait(PeerCloseTimeout)
    except CatchableError:
      discard

  await sconn.close()
  await conn.close()
  await transport.stop()

waitFor(main())
