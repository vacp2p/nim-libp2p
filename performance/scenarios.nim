# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../tests/helpers
import ./runner

suite "Performance Tests":
  teardown:
    checkTrackers()

  asyncTest "Base Test":
    run()

  asyncTest "Network Delay Test":
    run(
      preExecCmd =
        "tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal",
      postExecCmd = "tc qdisc del dev eth0 root",
    )
