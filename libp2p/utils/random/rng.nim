# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import bearssl/rand
export PrngClass

type
  Rng* = ref object of RootObj
    vtable*: ptr ptr PrngClass

method shuffle*[T](
  rng: Rng,
  x: var openArray[T]) {.base.} =
  raiseAssert("Not implemented!")

method generate*(rng: Rng, v: var openArray[byte]) {.base.} =
  raiseAssert("Not implemented!")
