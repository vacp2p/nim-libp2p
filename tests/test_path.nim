# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/os
import ./imports

const test_path {.strdefine.} = ""

when test_path == "":
  {.error: "Please specify test_path via -d:test_path=\"path/to/test\" (e.g., -d:test_path=\"quic\" or -d:test_path=\"transports/testws\")".}

importTestsMatching(currentSourcePath().parentDir(), test_path)

# Run final trackers check.
# After all tests are executed final trackers check is performed to ensure that
# there isn't anything left open.
# This can usually happen when last imported/executed tests do not call checkTrackers.
from ./tools/unittest import finalCheckTrackers
finalCheckTrackers()
