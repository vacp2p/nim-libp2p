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

proc intoCurve25519Key*(s: openarray[byte]): Curve25519Key =
  assert s.len == Curve25519KeySize
  copyMem(addr result[0], unsafeaddr s[0], Curve25519KeySize)

proc getBytes*(key: Curve25519Key): seq[byte] = @key

const
  ForbiddenCurveValues: array[12, Curve25519Key] = [
                [0.byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [1.byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [224.byte, 235, 122, 124, 59, 65, 184, 174, 22, 86, 227, 250, 241, 159, 196, 106, 218, 9, 141, 235, 156, 50, 177, 253, 134, 98, 5, 22, 95, 73, 184, 0],
                [95.byte, 156, 149, 188, 163, 80, 140, 36, 177, 208, 177, 85, 156, 131, 239, 91, 4, 68, 92, 196, 88, 28, 142, 134, 216, 34, 78, 221, 208, 159, 17, 87],
                [236.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 127],
                [237.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 127],
                [238.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 127],
                [205.byte, 235, 122, 124, 59, 65, 184, 174, 22, 86, 227, 250, 241, 159, 196, 106, 218, 9, 141, 235, 156, 50, 177, 253, 134, 98, 5, 22, 95, 73, 184, 128],
                [76.byte, 156, 149, 188, 163, 80, 140, 36, 177, 208, 177, 85, 156, 131, 239, 91, 4, 68, 92, 196, 88, 28, 142, 134, 216, 34, 78, 221, 208, 159, 17, 215],
                [217.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
                [218.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
                [219.byte, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 25],
        ]

proc byteswap(buf: var Curve25519Key) {.inline.} =
  for i in 0..<16:
    let
      x = buf[i]
    buf[i] = buf[31 - i]
    buf[31 - i] = x

proc mul*(_: type[Curve25519], dst: var Curve25519Key, scalar: Curve25519Key, point: Curve25519Key) =
  let defaultBrEc = brEcGetDefault()

  # The source point is provided in array G (of size Glen bytes);
  # the multiplication result is written over it.
  dst = scalar

  # point needs to be big-endian
  var
    rpoint = point
  rpoint.byteswap()
  let
    res = defaultBrEc.mul(
      cast[pcuchar](addr dst[0]),
      Curve25519KeySize,
      cast[pcuchar](addr rpoint[0]),
      Curve25519KeySize,
      EC_curve25519)
  assert res == 1

proc mulgen*(_: type[Curve25519], dst: var Curve25519Key, point: Curve25519Key) =
  let defaultBrEc = brEcGetDefault()

  var
    rpoint = point
  rpoint.byteswap()

  block iterate:
    while true:
      block derive:
        let
          size = defaultBrEc.mulgen(
            cast[pcuchar](addr dst[0]),
            cast[pcuchar](addr rpoint[0]),
            Curve25519KeySize,
            EC_curve25519)
        assert size == Curve25519KeySize
        for forbid in ForbiddenCurveValues:
          if dst == forbid:
            break derive
        break iterate

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
