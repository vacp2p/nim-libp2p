# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../../tests/helpers
import ./base_test

suite "Performance Tests":
  teardown:
    checkTrackers()

asyncTest "Base Test (TCP+Yamux)":
  await baseTest("TCP Yamux")

asyncTest "Base Test (QUIC)":
  await baseTest("QUIC", useQuic = true)