## Nim-Libp2p
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module integrates BearSSL ChaCha20+Poly1305
##
## This module uses unmodified parts of code from
## BearSSL library <https://bearssl.org/>
## Copyright(C) 2018 Thomas Pornin <pornin@bolet.org>.

# RFC @ https://tools.ietf.org/html/rfc7539

import bearssl

const
  ChaChaPolyKeySize = 32
  ChaChaPolyNonceSize = 12
  ChaChaPolyTagSize = 16
  
type
  ChaChaPoly* = object
  ChaChaPolyKey* = array[ChaChaPolyKeySize, byte]
  ChaChaPolyNonce* = array[ChaChaPolyNonceSize, byte]
  ChaChaPolyTag* = array[ChaChaPolyTagSize, byte]

proc intoChaChaPolyKey*(s: array[32, byte]): ChaChaPolyKey =
  assert s.len == ChaChaPolyKeySize
  copyMem(addr result[0], unsafeaddr s[0], ChaChaPolyKeySize)
  
proc intoChaChaPolyKey*(s: seq[byte]): ChaChaPolyKey =
  assert s.len == ChaChaPolyKeySize
  copyMem(addr result[0], unsafeaddr s[0], ChaChaPolyKeySize)

proc intoChaChaPolyNonce*(s: seq[byte]): ChaChaPolyNonce =
  assert s.len == ChaChaPolyNonceSize
  copyMem(addr result[0], unsafeaddr s[0], ChaChaPolyNonceSize)

proc intoChaChaPolyTag*(s: seq[byte]): ChaChaPolyTag =
  assert s.len == ChaChaPolyTagSize
  copyMem(addr result[0], unsafeaddr s[0], ChaChaPolyTagSize)
  
# bearssl allows us to use optimized versions
# this is reconciled at runtime
# we do this in the global scope / module init

template fetchImpl: untyped =
  # try for the best first
  let
    chachapoly_native_impl {.inject.}: Poly1305Run = poly1305CtmulRun
    chacha_native_impl {.inject.}: Chacha20Run = chacha20CtRun

proc encrypt*(_: type[ChaChaPoly],
                 key: ChaChaPolyKey,
                 nonce: ChaChaPolyNonce,
                 tag: var ChaChaPolyTag,
                 data: var openarray[byte],
                 aad: openarray[byte]) =
  fetchImpl()

  let
    ad = if aad.len > 0:
           unsafeaddr aad[0]
         else:
           nil

  chachapoly_native_impl(
    unsafeaddr key[0],
    unsafeaddr nonce[0],
    addr data[0],
    data.len,
    ad,
    aad.len,
    addr tag[0],
    chacha_native_impl,
    #[encrypt]# 1.cint)

proc decrypt*(_: type[ChaChaPoly],
                 key: ChaChaPolyKey,
                 nonce: ChaChaPolyNonce,
                 tag: var ChaChaPolyTag,
                 data: var openarray[byte],
                 aad: openarray[byte]) =
  fetchImpl()

  let
    ad = if aad.len > 0:
          unsafeaddr aad[0]
         else:
           nil
  
  chachapoly_native_impl(
    unsafeaddr key[0],
    unsafeaddr nonce[0],
    addr data[0],
    data.len,
    ad,
    aad.len,
    addr tag[0],
    chacha_native_impl,
    #[decrypt]# 0.cint)
