## Nim-Libp2p
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module integrates BearSSL Cyrve25519 mul and mulgen
##
## This module uses unmodified parts of code from
## BearSSL library <https://bearssl.org/>
## Copyright(C) 2018 Thomas Pornin <pornin@bolet.org>.

# RFC @ https://tools.ietf.org/html/rfc7748

{.push raises: [Defect].}

import bearssl
import stew/results
export results

const
  Curve25519KeySize* = 32

type
  Curve25519* = object
  Curve25519Key* = array[Curve25519KeySize, byte]
  pcuchar = ptr cuchar
  Curve25519Error* = enum
    Curver25519GenError

proc intoCurve25519Key*(s: openArray[byte]): Curve25519Key =
  assert s.len == Curve25519KeySize
  copyMem(addr result[0], unsafeAddr s[0], Curve25519KeySize)

proc getBytes*(key: Curve25519Key): seq[byte] = @key

proc byteswap(buf: var Curve25519Key) {.inline.} =
  for i in 0..<16:
    let
      x = buf[i]
    buf[i] = buf[31 - i]
    buf[31 - i] = x

proc mul*(_: type[Curve25519], point: var Curve25519Key, multiplier: Curve25519Key) =
  let defaultBrEc = brEcGetDefault()

  # multiplier needs to be big-endian
  var
    multiplierBs = multiplier
  multiplierBs.byteswap()
  let
    res = defaultBrEc.mul(
      cast[pcuchar](addr point[0]),
      Curve25519KeySize,
      cast[pcuchar](addr multiplierBs[0]),
      Curve25519KeySize,
      EC_curve25519)
  assert res == 1

proc mulgen(_: type[Curve25519], dst: var Curve25519Key, point: Curve25519Key) =
  let defaultBrEc = brEcGetDefault()

  var
    rpoint = point
  rpoint.byteswap()

  let
    size = defaultBrEc.mulgen(
      cast[pcuchar](addr dst[0]),
      cast[pcuchar](addr rpoint[0]),
      Curve25519KeySize,
      EC_curve25519)
  
  assert size == Curve25519KeySize

proc public*(private: Curve25519Key): Curve25519Key =
  Curve25519.mulgen(result, private)

proc random*(_: type[Curve25519Key], rng: var BrHmacDrbgContext): Curve25519Key =
  var res: Curve25519Key
  let defaultBrEc = brEcGetDefault()
  let len = brEcKeygen(
    addr rng.vtable, defaultBrEc, nil, addr res[0], EC_curve25519)
  # Per bearssl documentation, the keygen only fails if the curve is
  # unrecognised -
  doAssert len == Curve25519KeySize, "Could not generate curve"

  res
