# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import results
import ../../libp2p/protocols/connectivity/autonat/types

export types

const MinTestConfidence* = 0.3
  ## Confidence that a test waits for before it trusts a verdict. The value is
  ## empirically chosen: the autonat services pass it after the first answers of
  ## a probe window, so a test does not wait for full confidence.

func settled*(
    reachability, expected: NetworkReachability, confidence: Opt[float]
): bool =
  ## Whether autonat settled on ``expected`` with enough confidence for a test.
  reachability == expected and confidence.isSome() and
    confidence.get() >= MinTestConfidence
