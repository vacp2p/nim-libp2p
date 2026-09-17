# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# https://tools.ietf.org/html/rfc5869

{.push raises: [].}

import nimcrypto/[hash, hmac, sha2, utils]

type HkdfResult*[len: static int] = array[len, byte]

func extract[T: sha256](salt, ikm: openArray[byte]): MDigest[T.bits] =
  var ctx: HMAC[T]
  defer:
    ctx.clear()

  ctx.init(salt)
  ctx.update(ikm)
  ctx.finish()

func hkdf*[T: sha256, len: static int](
    _: type[T],
    salt, ikm, info: openArray[byte],
    outputs: var openArray[HkdfResult[len]],
) =
  ## `outputs` is one continuous OKM stream: `outputs[1]` continues `outputs[0]`.
  const hashLen = T.bits div 8
  doAssert outputs.len * len <= 255 * hashLen, "HKDF output is too long"

  var
    prk = extract[T](salt, ikm)
    t: MDigest[T.bits]
    tLen = 0
    used = 0
    counter = 1'u8

  defer:
    burnMem(prk)
    burnMem(t)

  for output in outputs.mitems:
    var filled = 0
    while filled < len:
      if used == tLen:
        var ctx: HMAC[T]
        ctx.init(prk.data)
        if tLen > 0:
          ctx.update(t.data)
        ctx.update(info)
        ctx.update([counter])
        t = ctx.finish()
        ctx.clear()

        tLen = hashLen
        used = 0
        inc counter

      let chunk = min(tLen - used, len - filled)
      copyMem(addr output[filled], addr t.data[used], chunk)
      filled += chunk
      used += chunk
