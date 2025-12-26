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

const path {.strdefine.} = ""

when path == "":
  # Run all tests in libp2p, tools, and interop
  importTests(currentSourcePath().parentDir() / "libp2p", @["multiformat_exts"])
  importTests(currentSourcePath().parentDir() / "tools", @[])
  importTests(currentSourcePath().parentDir() / "interop", @[])
else:
  # Run tests that match specific path substring
  importTests(currentSourcePath().parentDir(), @[], path)

# Run final trackers check.
# After all tests are executed final trackers check is performed to ensure that
# there isn't anything left open.
# This can usually happen when last imported/executed tests do not call checkTrackers.
from ./tools/unittest import finalCheckTrackers
finalCheckTrackers()
