# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ./[unittest, futures]

suite "Test future helpers":
  asyncTest "allFuturesRaising propagates a cancelled child":
    let child = sleepAsync(1.hours)
    await child.cancelAndWait()
    expect CancelledError:
      await allFuturesRaising(child)
