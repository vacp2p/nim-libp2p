# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# https://tools.ietf.org/html/rfc5869

{.push raises: [].}

import nimcrypto
import boringssl

type HkdfResult*[len: static int] = array[len, byte]

proc hkdf*[T: sha256, len: static int](
    _: type[T],
    salt, ikm, info: openArray[byte],
    outputs: var openArray[HkdfResult[len]],
) =
  if outputs.len == 0:
    return

  let totalLen = outputs.len * len
  if totalLen == 0:
    return

  let res = HKDF(
    addr outputs[0][0],
    csize_t(totalLen),
    EVP_sha256(),
    if ikm.len > 0:
      unsafeAddr ikm[0]
    else:
      nil,
    csize_t(ikm.len),
    if salt.len > 0:
      unsafeAddr salt[0]
    else:
      nil,
    csize_t(salt.len),
    if info.len > 0:
      unsafeAddr info[0]
    else:
      nil,
    csize_t(info.len),
  )
  doAssert res == 1, "HKDF failed"
