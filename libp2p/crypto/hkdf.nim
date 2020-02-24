## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# https://tools.ietf.org/html/rfc5869

import math
import nimcrypto

iterator hkdf*(H: typedesc, salt, ikm, info: openarray[byte]): MDigest[H.bits] {.inline.} =
  var
    prk = H.hmac(salt, ikm)
    t: seq[byte]
    okm: seq[byte]
    i = 1

  while true:
    var ctx: HMAC[H]
    ctx.init(prk.data)
    ctx.update(t)
    ctx.update(info)
    ctx.update([i.byte])
    var next = ctx.finish()
    yield next
    t.setLen(0)
    t &= next.data
    inc i 

# notice we use this call under only in a test, prefer iterator!
proc hkdf*(H: typedesc, salt, ikm, info: openarray[byte], output: var openarray[byte]) =
  const
    HASHLEN = H.bits div 8

  var
    max = ceil(output.len / HASHLEN).int
    okm: seq[byte]
  
  for next in H.hkdf(salt, ikm, info):
    if max == 0:
      break
    okm &= next.data
    dec max

  copyMem(addr output[0], addr okm[0], output.len)


