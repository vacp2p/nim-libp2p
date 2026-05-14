# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# RFC @ https://tools.ietf.org/html/rfc7539

{.push raises: [].}

import boringssl
from stew/assign2 import assign
import ../utils/sequninit

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
  assign(result, s)

proc intoChaChaPolyNonce*(s: openArray[byte]): ChaChaPolyNonce =
  assert s.len == ChaChaPolyNonceSize
  assign(result, s)

proc intoChaChaPolyTag*(s: openArray[byte]): ChaChaPolyTag =
  assert s.len == ChaChaPolyTagSize
  assign(result, s)

template dataPtr(data: var openArray[byte]): ptr uint8 =
  if data.len > 0:
    addr data[0]
  else:
    nil

template dataPtr(data: openArray[byte]): ptr uint8 =
  if data.len > 0:
    unsafeAddr data[0]
  else:
    nil

proc newContext(key: ChaChaPolyKey): ptr EVP_AEAD_CTX =
  let ctx = EVP_AEAD_CTX_new(
    EVP_aead_chacha20_poly1305(),
    unsafeAddr key[0],
    csize_t(key.len),
    csize_t(ChaChaPolyTagSize),
  )
  doAssert not ctx.isNil, "Could not initialize ChaCha20-Poly1305"
  ctx

proc encrypt*(
    _: type[ChaChaPoly],
    key: ChaChaPolyKey,
    nonce: ChaChaPolyNonce,
    tag: var ChaChaPolyTag,
    data: var openArray[byte],
    aad: openArray[byte],
) =
  let ctx = newContext(key)
  defer:
    EVP_AEAD_CTX_free(ctx)

  var
    outLen: csize_t
    outBuf = newSeqUninit[byte](data.len + ChaChaPolyTagSize)

  let res = EVP_AEAD_CTX_seal(
    ctx,
    addr outBuf[0],
    addr outLen,
    csize_t(outBuf.len),
    unsafeAddr nonce[0],
    csize_t(nonce.len),
    data.dataPtr,
    csize_t(data.len),
    aad.dataPtr,
    csize_t(aad.len),
  )
  doAssert res == 1 and outLen == csize_t(outBuf.len), "ChaCha20-Poly1305 seal failed"

  if data.len > 0:
    copyMem(addr data[0], addr outBuf[0], data.len)
  copyMem(addr tag[0], addr outBuf[data.len], tag.len)

proc decrypt*(
    _: type[ChaChaPoly],
    key: ChaChaPolyKey,
    nonce: ChaChaPolyNonce,
    tag: var ChaChaPolyTag,
    data: var openArray[byte],
    aad: openArray[byte],
): bool =
  let ctx = newContext(key)
  defer:
    EVP_AEAD_CTX_free(ctx)

  var inBuf = newSeqUninit[byte](data.len + ChaChaPolyTagSize)
  if data.len > 0:
    copyMem(addr inBuf[0], addr data[0], data.len)
  copyMem(addr inBuf[data.len], addr tag[0], tag.len)

  var
    outLen: csize_t
    outBuf = newSeqUninit[byte](max(data.len, 1))

  let res = EVP_AEAD_CTX_open(
    ctx,
    addr outBuf[0],
    addr outLen,
    csize_t(data.len),
    unsafeAddr nonce[0],
    csize_t(nonce.len),
    addr inBuf[0],
    csize_t(inBuf.len),
    aad.dataPtr,
    csize_t(aad.len),
  )
  if res != 1 or outLen != csize_t(data.len):
    return false

  if data.len > 0:
    copyMem(addr data[0], addr outBuf[0], data.len)
  true
