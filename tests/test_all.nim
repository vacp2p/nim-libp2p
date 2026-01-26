# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import std/os
import ./imports

const path {.strdefine.} = ""

when path == "":
  # Run all tests in libp2p and tools
  importTests(currentSourcePath().parentDir() / "libp2p", @["multiformat_exts"])
  importTests(currentSourcePath().parentDir() / "interop", @[])
  importTests(currentSourcePath().parentDir() / "tools", @[])
else:
  # Run tests that match specific path substring
  importTests(currentSourcePath().parentDir(), @[], path)

# Run final trackers check.
# After all tests are executed final trackers check is performed to ensure that
# there isn't anything left open.
# This can usually happen when last imported/executed tests do not call checkTrackers.
from ./tools/unittest import finalCheckTrackers
finalCheckTrackers()
