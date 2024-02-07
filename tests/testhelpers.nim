{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ./helpers

suite "Helpers":

  asyncTest "checkExpiring should pass if the condition is true":
    let a = 2
    let b = 2
    checkExpiring: a == b

  asyncTest "checkExpiring should pass if the condition is true, custom timeout":
    let a = 2
    let b = 2
    checkExpiring(a == b, 2.seconds)

  asyncTest "checkExpiring should pass if the conditions are true":
    let a = 2
    let b = 2
    checkExpiring:
        a == b
        a == 2
        b == 2
