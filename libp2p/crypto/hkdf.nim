# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# https://tools.ietf.org/html/rfc5869

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import nimcrypto
import bearssl/[kdf, hash]

type HkdfResult*[len: static int] = array[len, byte]

proc hkdf*[T: sha256; len: static int](_: type[T]; salt, ikm, info: openArray[byte]; outputs: var openArray[HkdfResult[len]]) =
  var
    ctx: HkdfContext
  hkdfInit(
    ctx, addr sha256Vtable,
    if salt.len > 0: unsafeAddr salt[0] else: nil, csize_t(salt.len))
  hkdfInject(
    ctx, if ikm.len > 0: unsafeAddr ikm[0] else: nil, csize_t(ikm.len))
  hkdfFlip(ctx)
  for i in 0..outputs.high:
    discard hkdfProduce(
      ctx,
      if info.len > 0: unsafeAddr info[0]
      else: nil, csize_t(info.len),
      addr outputs[i][0], csize_t(outputs[i].len))
