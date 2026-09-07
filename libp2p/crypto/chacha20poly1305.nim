# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module integrates BoringSSL ChaCha20+Poly1305

# RFC @ https://tools.ietf.org/html/rfc7539

{.push raises: [].}

import boringssl
from stew/assign2 import assign
from stew/ptrops import baseAddr

const
  ChaChaPolyKeySize = 32
  ChaChaPolyNonceSize = 12
  ChaChaPolyTagSize = 16

type
  ChaChaPoly* = object
  ChaChaPolyKey* = array[ChaChaPolyKeySize, byte]
  ChaChaPolyNonce* = array[ChaChaPolyNonceSize, byte]
  ChaChaPolyTag* = array[ChaChaPolyTagSize, byte]

proc intoChaChaPolyKey*(s: openArray[byte]): ChaChaPolyKey =
  assert s.len == ChaChaPolyKeySize
  var key: ChaChaPolyKey
  assign(key, s)
  key

proc intoChaChaPolyNonce*(s: openArray[byte]): ChaChaPolyNonce =
  assert s.len == ChaChaPolyNonceSize
  var nonce: ChaChaPolyNonce
  assign(nonce, s)
  nonce

proc intoChaChaPolyTag*(s: openArray[byte]): ChaChaPolyTag =
  assert s.len == ChaChaPolyTagSize
  var tag: ChaChaPolyTag
  assign(tag, s)
  tag

template withAeadCtx(key: ChaChaPolyKey, body: untyped) =
  # This AEAD keeps no heap state, so a per-call context is cheaper than caching one.
  block:
    var ctx {.inject.}: EVP_AEAD_CTX
    if EVP_AEAD_CTX_init(
      addr ctx,
      EVP_aead_chacha20_poly1305(),
      addr key[0],
      csize_t(ChaChaPolyKeySize),
      csize_t(ChaChaPolyTagSize),
      nil,
    ) != 1:
      raiseAssert "EVP_AEAD_CTX_init failed for ChaChaPoly"
    defer:
      EVP_AEAD_CTX_cleanup(addr ctx)

    body

proc encrypt*(
    _: type[ChaChaPoly],
    key: ChaChaPolyKey,
    nonce: ChaChaPolyNonce,
    tag: var ChaChaPolyTag,
    data: var openArray[byte],
    aad: openArray[byte],
) =
  ## Encrypts `data` in place, writing its tag to `tag`, which must not alias `data`.
  let ad =
    if aad.len > 0:
      addr aad[0]
    else:
      nil

  var tagLen: csize_t
  withAeadCtx(key):
    if EVP_AEAD_CTX_seal_scatter(
      addr ctx,
      baseAddr(data),
      addr tag[0],
      addr tagLen,
      csize_t(ChaChaPolyTagSize),
      addr nonce[0],
      csize_t(ChaChaPolyNonceSize),
      baseAddr(data),
      csize_t(data.len),
      nil,
      0,
      ad,
      csize_t(aad.len),
    ) != 1:
      raiseAssert "EVP_AEAD_CTX_seal_scatter failed for ChaChaPoly"
    doAssert tagLen == csize_t(ChaChaPolyTagSize)

proc decrypt*(
    _: type[ChaChaPoly],
    key: ChaChaPolyKey,
    nonce: ChaChaPolyNonce,
    tag: ChaChaPolyTag,
    data: var openArray[byte],
    aad: openArray[byte],
): bool =
  ## Decrypts `data` in place, returning false and zeroing it when `tag` fails.
  let ad =
    if aad.len > 0:
      addr aad[0]
    else:
      nil

  var authenticated = false
  withAeadCtx(key):
    authenticated =
      EVP_AEAD_CTX_open_gather(
        addr ctx,
        baseAddr(data),
        addr nonce[0],
        csize_t(ChaChaPolyNonceSize),
        baseAddr(data),
        csize_t(data.len),
        addr tag[0],
        csize_t(ChaChaPolyTagSize),
        ad,
        csize_t(aad.len),
      ) == 1

  authenticated
