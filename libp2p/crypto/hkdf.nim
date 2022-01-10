## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# https://tools.ietf.org/html/rfc5869

{.push raises: [Defect].}

import nimcrypto
import bearssl

type
  BearHKDFContext {.importc: "br_hkdf_context", header: "bearssl_kdf.h".} = object
  HKDFResult*[len: static int] = array[len, byte]

proc br_hkdf_init(ctx: ptr BearHKDFContext; hashClass: ptr HashClass; salt: pointer; len: csize_t) {.importc: "br_hkdf_init", header: "bearssl_kdf.h", raises: [].}
proc br_hkdf_inject(ctx: ptr BearHKDFContext; ikm: pointer; len: csize_t) {.importc: "br_hkdf_inject", header: "bearssl_kdf.h", raises: [].}
proc br_hkdf_flip(ctx: ptr BearHKDFContext) {.importc: "br_hkdf_flip", header: "bearssl_kdf.h", raises: [].}
proc br_hkdf_produce(ctx: ptr BearHKDFContext; info: pointer; infoLen: csize_t; output: pointer; outputLen: csize_t) {.importc: "br_hkdf_produce", header: "bearssl_kdf.h", raises: [].}

proc hkdf*[T: sha256; len: static int](_: type[T]; salt, ikm, info: openArray[byte]; outputs: var openArray[HKDFResult[len]]) =
  var
    ctx: BearHKDFContext
  br_hkdf_init(
    addr ctx, addr sha256Vtable,
    if salt.len > 0: unsafeAddr salt[0] else: nil, csize_t(salt.len))
  br_hkdf_inject(
    addr ctx, if ikm.len > 0: unsafeAddr ikm[0] else: nil, csize_t(ikm.len))
  br_hkdf_flip(addr ctx)
  for i in 0..outputs.high:
    br_hkdf_produce(
      addr ctx,
      if info.len > 0: unsafeAddr info[0]
      else: nil, csize_t(info.len),
      addr outputs[i][0], csize_t(outputs[i].len))
