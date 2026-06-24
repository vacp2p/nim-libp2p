# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/os
import ./imports

const path {.strdefine.} = ""

when path == "":
  # Run a subsystem group (or every group when testGroup is empty).
  importTestGroup(currentSourcePath().parentDir(), testGroup)
else:
  # Run tests that match a specific path substring (make test <path>).
  importTests(currentSourcePath().parentDir(), @[], path)

# Run final trackers check.
# After all tests are executed final trackers check is performed to ensure that
# there isn't anything left open.
# This can usually happen when last imported/executed tests do not call checkTrackers.
from ./tools/unittest import finalCheckTrackers
finalCheckTrackers()
