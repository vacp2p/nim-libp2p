# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../tests/utils/async_tests
import ./runner

suite "Performance Tests":
  asyncTest "Base Test TCP":
    run("TCP")

  asyncTest "Base Test QUIC":
    run("QUIC")
