# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[monotimes, times]
import bearssl/blockx
from stew/ptrops import baseAddr
import ../../../libp2p/crypto/chacha20poly1305
import ../../tools/unittest

const
  ChunkSize = 1 shl 20
  Chunks = 64
  WarmupChunks = 4
  MinSpeedup = 2.0

type BearSslAead = object
  poly: Poly1305Run
  chacha: Chacha20Run

proc bestBearSslAead(): BearSslAead =
  ## The fastest ChaChaPoly BearSSL offers here; a `Get` returns nil when unsupported.
  var aead = BearSslAead(
    # cast is required to workaround https://github.com/nim-lang/Nim/issues/13905
    poly: cast[Poly1305Run](poly1305CtmulRun),
    chacha: cast[Chacha20Run](chacha20CtRun),
  )

  let poly = poly1305CtmulqGet()
  if not poly.isNil():
    aead.poly = poly

  let chacha = chacha20Sse2Get()
  if not chacha.isNil():
    aead.chacha = chacha

  aead

proc encrypt(
    aead: BearSslAead,
    key: ChaChaPolyKey,
    nonce: ChaChaPolyNonce,
    tag: var ChaChaPolyTag,
    data: var openArray[byte],
) =
  aead.poly(
    addr key[0],
    addr nonce[0],
    baseAddr(data),
    csize_t(data.len),
    nil,
    0,
    baseAddr(tag),
    aead.chacha,
    1.cint,
  )

template elapsedSeconds(body: untyped): float =
  block:
    let start = getMonoTime()
    body
    float(inNanoseconds(getMonoTime() - start)) / 1e9

suite "ChaChaPoly throughput":
  test "the AEAD backend outruns the best BearSSL path":
    var
      key: ChaChaPolyKey
      nonce: ChaChaPolyNonce
      tag: ChaChaPolyTag
      noaad: array[0, byte]
      data = newSeq[byte](ChunkSize)
    for i in 0 ..< key.len:
      key[i] = byte(i)

    let bear = bestBearSslAead()

    for _ in 0 ..< WarmupChunks:
      ChaChaPoly.encrypt(key, nonce, tag, data, noaad)
      bear.encrypt(key, nonce, tag, data)

    let libp2pSeconds = elapsedSeconds:
      for _ in 0 ..< Chunks:
        ChaChaPoly.encrypt(key, nonce, tag, data, noaad)

    let bearSeconds = elapsedSeconds:
      for _ in 0 ..< Chunks:
        bear.encrypt(key, nonce, tag, data)

    let megabytes = float(ChunkSize) * float(Chunks) / 1048576.0
    echo "    libp2p ChaChaPoly: ", int(megabytes / libp2pSeconds), " MiB/s"
    echo "    BearSSL, best available path: ", int(megabytes / bearSeconds), " MiB/s"

    # BearSSL has no AVX2 or NEON ChaCha20 and no Poly1305 assembly on any target.
    check libp2pSeconds * MinSpeedup < bearSeconds
