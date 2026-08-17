# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, unittest2
import ./unittest_common

export unittest2 except suite
export unittest_common

## suite wraps unittest2.suite in a proc to avoid issue with too many global variables
## See https://github.com/nim-lang/Nim/issues/8500
template suite*(name: string, body: untyped): untyped =
  block:
    proc testSuite() =
      unittest2.suite name:
        body

    testSuite()

template asyncTeardown*(body: untyped): untyped =
  teardown:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

template asyncSetup*(body: untyped): untyped =
  setup:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

template finalCheckTrackers*(): untyped =
  # finalCheckTrackers is a utility used for performing a final tracker check 
  # outside the test suite. It should be called at the very end of a test file 
  # (typically containing a bundle of tests) to ensure that no tests have left 
  # any trackers open.

  unittest2.suite "Final checkTrackers":
    test "test":
      template checkpoint(msg: string) =
        unittest2.checkpoint(msg)

      template fail() =
        unittest2.fail()

      # checkTrackers must be executed within a suite or test. otherwise, 
      # its output won't appear on stdout.
      checkTrackers()
