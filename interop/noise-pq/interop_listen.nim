# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Standalone interop listener for NoiseHFS
## (`Noise_XXhfs_25519+MLKEM768_ChaChaPoly_SHA256`).
##
## Accepts one connection, completes the handshake as responder, sends one
## encrypted greeting and reads the reply, prints identity/greeting lines on
## a fixed stdout contract, and exits. Companion to interop_dial.nim - used
## to let another language's implementation dial into nim-libp2p to verify
## wire compatibility from the other direction.
##
## Usage:
##   nim c -r interop_listen.nim [port]   (default 9998)

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
    peerid,
    crypto/crypto,
    crypto/rng,
    protocols/secure/noisehfs,
    upgrademngrs/upgrade,
  ]

const GreetingPrefix = "hello from "

proc emit(line: string) =
  ## Write one contract line to stdout and flush immediately: stdout is
  ## fully buffered when redirected to a file, and the runner polls the log
  ## for READY/INTEROP_OK while this process is still alive.
  echo line
  stdout.flushFile()

proc firstLine(s: string): string =
  ## Only the first line of `s`, stripped. A peer could batch extra bytes
  ## into the same message as its greeting; RECV must always be exactly one
  ## clean line on stdout, not whatever else rode along in the frame.
  let nlPos = s.find('\n')
  (if nlPos >= 0: s[0 ..< nlPos] else: s).strip()

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

  emit("LOCAL " & $PeerId.init(privKey).get())
  await transport.start(@[listenMa])
  emit("READY " & $port)

  let conn = await transport.accept()
  let sconn = await noiseHFS.secure(conn, Opt.none(PeerId))
  emit("PEER " & $sconn.peerId)

  await sconn.write(GreetingPrefix & "Nim\n")
  emit("SENT " & GreetingPrefix & "Nim")
  let reply = firstLine(string.fromBytes(await sconn.readMessage()))
  emit("RECV " & reply)
  if not reply.startsWith(GreetingPrefix) or reply.len == GreetingPrefix.len:
    stderr.writeLine("ERROR unexpected greeting: " & reply)
    quit(1)

  await sconn.close()
  await conn.close()
  await transport.stop()
  # INTEROP_OK must be the very last thing this process prints: emit it only
  # once every cleanup step above has completed without raising. If any of
  # them raises, the top-level except below prints ERROR and exits 1 instead
  # - and never reaches this line.
  emit("INTEROP_OK")

try:
  waitFor(main())
except CatchableError as exc:
  stderr.writeLine("ERROR " & exc.msg)
  quit(1)
