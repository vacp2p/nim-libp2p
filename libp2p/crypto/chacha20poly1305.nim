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

{.push raises: [Defect].}

import bearssl

# have to do this due to a nim bug and raises[] on callbacks
# https://github.com/nim-lang/Nim/issues/13905
proc ourPoly1305CtmulRun*(key: pointer; iv: pointer; data: pointer; len: int;
                      aad: pointer; aadLen: int; tag: pointer; ichacha: pointer;
                      encrypt: cint) {.cdecl, importc: "br_poly1305_ctmul_run",
                                     header: "bearssl_block.h".}

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
  copyMem(addr result[0], unsafeAddr s[0], ChaChaPolyKeySize)

proc intoChaChaPolyNonce*(s: openArray[byte]): ChaChaPolyNonce =
  assert s.len == ChaChaPolyNonceSize
  copyMem(addr result[0], unsafeAddr s[0], ChaChaPolyNonceSize)

proc intoChaChaPolyTag*(s: openArray[byte]): ChaChaPolyTag =
  assert s.len == ChaChaPolyTagSize
  copyMem(addr result[0], unsafeAddr s[0], ChaChaPolyTagSize)

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

  ourPoly1305CtmulRun(
    unsafeAddr key[0],
    unsafeAddr nonce[0],
    addr data[0],
    data.len,
    ad,
    aad.len,
    addr tag[0],
    chacha20CtRun,
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

  ourPoly1305CtmulRun(
    unsafeAddr key[0],
    unsafeAddr nonce[0],
    addr data[0],
    data.len,
    ad,
    aad.len,
    addr tag[0],
    chacha20CtRun,
    #[decrypt]# 0.cint)
