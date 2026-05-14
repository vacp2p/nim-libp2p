# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# RFC @ https://tools.ietf.org/html/rfc7748

{.push raises: [].}

import boringssl
import results
from stew/assign2 import assign
import rng
export results

const Curve25519KeySize* = 32

type
  Curve25519* = object
  Curve25519Key* = array[Curve25519KeySize, byte]
  Curve25519Error* = enum
    Curver25519GenError

proc intoCurve25519Key*(s: openArray[byte]): Curve25519Key =
  assert s.len == Curve25519KeySize
  assign(result, s)

proc getBytes*(key: Curve25519Key): seq[byte] =
  @key

proc mul*(
    _: type[Curve25519], point: var Curve25519Key, multiplier: Curve25519Key
): bool =
  var shared: Curve25519Key
  let res = X25519(shared, multiplier, point)
  if res != 1:
    return false
  point = shared
  true

proc mulgen(_: type[Curve25519], dst: var Curve25519Key, point: Curve25519Key) =
  X25519_public_from_private(dst, point)

proc public*(private: Curve25519Key): Curve25519Key =
  Curve25519.mulgen(result, private)

proc random*(_: type[Curve25519Key], rng: Rng): Curve25519Key =
  var key: Curve25519Key
  rng.generate(key)
  key
