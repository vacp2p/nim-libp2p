# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Standalone interop listener for NoiseHFS
## (`Noise_XXhfs_25519+ML-KEM-768_ChaChaPoly_SHA256`).
##
## Accepts one connection, completes the handshake as responder, prints the
## remote peer id, and exits. Companion to interop_dial.nim - used to let
## another language's implementation dial into nim-libp2p to verify wire
## compatibility from the other direction.
##
## Usage:
##   nim c -r interop_listen.nim [port]   (default 9998)

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
    privKey = PrivateKey.random(Ed25519, rng).get()
    noiseHFS = NoiseHFS.new(rng, privKey)
    transport = TcpTransport.new(upgrade = Upgrade())
    listenMa = MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).get()

  await transport.start(@[listenMa])
  echo "READY ", port

  let conn = await transport.accept()
  let sconn = await noiseHFS.secure(conn, Opt.none(PeerId))

  echo "HANDSHAKE_OK remotePeer=", $sconn.peerId
  await sconn.close()
  await conn.close()
  await transport.stop()

waitFor(main())
