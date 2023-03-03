# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module integrates BearSSL ChaCha20+Poly1305
##
## This module uses unmodified parts of code from
## BearSSL library <https://bearssl.org/>
## Copyright(C) 2018 Thomas Pornin <pornin@bolet.org>.

# RFC @ https://tools.ietf.org/html/rfc7539

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import bearssl/blockx
from stew/assign2 import assign
from stew/ranges/ptr_arith import baseAddr

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

# bearssl allows us to use optimized versions
# this is reconciled at runtime
# we do this in the global scope / module init

proc encrypt*(_: type[ChaChaPoly],
                 key: ChaChaPolyKey,
                 nonce: ChaChaPolyNonce,
                 tag: var ChaChaPolyTag,
                 data: var openArray[byte],
                 aad: openArray[byte]) =
  let
    ad = if aad.len > 0:
           unsafeAddr aad[0]
         else:
           nil

  poly1305CtmulRun(
    unsafeAddr key[0],
    unsafeAddr nonce[0],
    baseAddr(data),
    uint(data.len),
    ad,
    uint(aad.len),
    baseAddr(tag),
    # cast is required to workaround https://github.com/nim-lang/Nim/issues/13905
    cast[Chacha20Run](chacha20CtRun),
    #[encrypt]# 1.cint)

proc decrypt*(_: type[ChaChaPoly],
                 key: ChaChaPolyKey,
                 nonce: ChaChaPolyNonce,
                 tag: var ChaChaPolyTag,
                 data: var openArray[byte],
                 aad: openArray[byte]) =
  let
    ad = if aad.len > 0:
          unsafeAddr aad[0]
         else:
           nil

  poly1305CtmulRun(
    unsafeAddr key[0],
    unsafeAddr nonce[0],
    baseAddr(data),
    uint(data.len),
    ad,
    uint(aad.len),
    baseAddr(tag),
    # cast is required to workaround https://github.com/nim-lang/Nim/issues/13905
    cast[Chacha20Run](chacha20CtRun),
    #[decrypt]# 0.cint)
