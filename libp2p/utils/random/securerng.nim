# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import rng
import bearssl/rand
import ../../crypto/crypto

export Rng

type
  SecureRng* = ref object of Rng
    hmacDrbgContext: ref HmacDrbgContext

method shuffle*[T](
  rng: SecureRng,
  x: var openArray[T]) =
  rng.hmacDrbgContext[].shuffle(x)

method generate*(rng: SecureRng, v: var openArray[byte]) =
  generate(rng.hmacDrbgContext[], v)

proc new*(
  T: typedesc[SecureRng]): T =
  var hmacDrbgContext = newRng()
  return T(hmacDrbgContext: hmacDrbgContext, vtable: addr hmacDrbgContext.vtable)