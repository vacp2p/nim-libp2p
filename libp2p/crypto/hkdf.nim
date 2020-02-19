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

proc hkdf*(H: typedesc, salt, ikm, info: openarray[byte], output: var openarray[byte]) =
  const
    HASHLEN = H.bits div 8
  
  var
    prk = H.hmac(salt, ikm)
    t: seq[byte]
    okm: seq[byte]
  
  for i in 0..<ceil(output.len / HASHLEN).int:
    var next = H.hmac(prk.data, t & @info & @[(i + 1).byte])
    t.setLen(0)
    t &= next.data
    okm &= t

  copyMem(addr output[0], addr okm[0], output.len)

