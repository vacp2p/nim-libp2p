# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[math, sets]
import ../../../libp2p/protocols/mix/delay_strategy
import ../../tools/[unittest, crypto]

const
  NumIterations = 100
  NumSamples = 10
  Tolerance = 0.2 # 20% tolerance for statistical tests
  BoundarySamples = 10000
  MaxBoundaryHitRatePct = 1
  MinBoundaryHitRatePct = 5
  ## Boundary-hit tests use large sample counts to make accidental spikes at the
  ## configured min/max easy to detect while leaving room for normal rounding
  ## into the boundary bucket after float -> uint16 conversion.

proc sampleUpperBoundStats(
    strategy: DelayStrategy, encodedDelay, maximumDelay: Delay, sampleCount: int
): tuple[maximumDelayHits: int, sawDelayBelowMaximum: bool] =
  var
    maximumDelayHits = 0
    sawDelayBelowMaximum = false

  for _ in 0 ..< sampleCount:
    let delay = strategy.generateForIntermediate(encodedDelay)
    check delay <= maximumDelay
    if delay == maximumDelay:
      inc maximumDelayHits
    elif delay < maximumDelay:
      sawDelayBelowMaximum = true

  (maximumDelayHits, sawDelayBelowMaximum)

proc sampleLowerBoundStats(
    strategy: DelayStrategy, encodedDelay, minimumDelay: Delay, sampleCount: int
): tuple[minimumDelayHits: int, sawDelayAboveMinimum: bool] =
  var
    minimumDelayHits = 0
    sawDelayAboveMinimum = false

  for _ in 0 ..< sampleCount:
    let delay = strategy.generateForIntermediate(encodedDelay)
    check delay >= minimumDelay
    if delay == minimumDelay:
      inc minimumDelayHits
    elif delay > minimumDelay:
      sawDelayAboveMinimum = true

  (minimumDelayHits, sawDelayAboveMinimum)

suite "DelayStrategy":
  test "NoSamplingDelayStrategy generateForEntry returns values in [0, 2]":
    let strategy = NoSamplingDelayStrategy.new(rng())

    for _ in 0 ..< NumIterations:
      check strategy.generateForEntry() <= 2

  test "NoSamplingDelayStrategy generateForIntermediate returns encoded value":
    let strategy = NoSamplingDelayStrategy.new(rng())

    check:
      strategy.generateForIntermediate(100) == 100
      strategy.generateForIntermediate(200) == 200

  test "ExponentialDelayStrategy generateForEntry returns configured mean":
    let rng = rng()

    check:
      ExponentialDelayStrategy.new(50, rng).generateForEntry() == 50
      ExponentialDelayStrategy.new(100, rng).generateForEntry() == 100

  test "ExponentialDelayStrategy generateForIntermediate returns 0 for mean 0":
    let strategy = ExponentialDelayStrategy.new(0, rng())

    check strategy.generateForIntermediate(0) == 0

  test "ExponentialDelayStrategy generateForIntermediate samples from exponential distribution":
    let
      strategy = ExponentialDelayStrategy.new(100, rng())
      meanDelay: Delay = 100
      numSamples = 1000
    var sum: float64 = 0

    for _ in 0 ..< numSamples:
      let delay = strategy.generateForIntermediate(meanDelay)
      sum += float64(delay)

    let empiricalMean = sum / float64(numSamples)
    # Allow 20% tolerance for statistical variation
    check:
      empiricalMean > float64(meanDelay) * (1 - Tolerance)
      empiricalMean < float64(meanDelay) * (1 + Tolerance)

  test "ExponentialDelayStrategy produces variable delays":
    let
      strategy = ExponentialDelayStrategy.new(100, rng())
      meanDelay: Delay = 100

    var delays = initHashSet[Delay]()
    for _ in 0 ..< NumSamples:
      let delay = strategy.generateForIntermediate(meanDelay)
      delays.incl(delay)

    check delays.len > NumSamples div 2

  test "ExponentialDelayStrategy never samples above the practical maximum":
    let
      meanDelay: Delay = 100
      negligibleProb = 0.01
      strategy = ExponentialDelayStrategy.new(meanDelay, rng(), negligibleProb)
      # maxDelay = -mean * ln(negligibleProb)
      maxDelay = Delay(-float64(meanDelay) * ln(negligibleProb))
      (maxDelayHits, sawDelayBelowMaximum) =
        sampleUpperBoundStats(strategy, meanDelay, maxDelay, BoundarySamples)

    check sawDelayBelowMaximum
    check maxDelayHits * 100 < BoundarySamples * MaxBoundaryHitRatePct

  test "ExponentialDelayStrategy respects custom negligibleProb":
    let
      meanDelay: Delay = 100
      negligibleProb = 0.01 # aggressive truncation: max ≈ mean * 4.6
      strategy = ExponentialDelayStrategy.new(meanDelay, rng(), negligibleProb)
      maxDelay = Delay(-float64(meanDelay) * ln(negligibleProb))

    for _ in 0 ..< 10000:
      check strategy.generateForIntermediate(meanDelay) <= maxDelay

  test "ExponentialDelayStrategy never samples below the configured minimum":
    let
      meanDelay: Delay = 100
      minimumDelay: Delay = 100
      strategy =
        ExponentialDelayStrategy.new(meanDelay, rng(), minimumDelay = minimumDelay)
      (minimumDelayHits, sawDelayAboveMinimum) =
        sampleLowerBoundStats(strategy, meanDelay, minimumDelay, BoundarySamples)

    check minimumDelayHits > 0
    check sawDelayAboveMinimum
    check minimumDelayHits * 100 < BoundarySamples * MinBoundaryHitRatePct

  test "ExponentialDelayStrategy falls back to minimum when floor exceeds practical maximum":
    let
      meanDelay: Delay = 100
      negligibleProb = 0.01
      minimumDelay: Delay = 500
      strategy = ExponentialDelayStrategy.new(
        meanDelay, rng(), negligibleProb = negligibleProb, minimumDelay = minimumDelay
      )

    check strategy.generateForIntermediate(meanDelay) == minimumDelay

  test "SpamProtectionDelayStrategy applies the default delay floor":
    let
      meanDelay: Delay = 100
      strategy = SpamProtectionDelayStrategy.new(meanDelay, rng())
      (minimumDelayHits, sawDelayAboveMinimum) = sampleLowerBoundStats(
        strategy, meanDelay, DefaultSpamProtectionDelayFloor, BoundarySamples
      )

    check minimumDelayHits > 0
    check sawDelayAboveMinimum
    check minimumDelayHits * 100 < BoundarySamples * MinBoundaryHitRatePct

  test "SpamProtectionDelayStrategy allows overriding the default delay floor":
    let
      meanDelay: Delay = 100
      minimumDelay: Delay = 250
      strategy =
        SpamProtectionDelayStrategy.new(meanDelay, rng(), minimumDelay = minimumDelay)
      (minimumDelayHits, sawDelayAboveMinimum) =
        sampleLowerBoundStats(strategy, meanDelay, minimumDelay, BoundarySamples)

    check minimumDelayHits > 0
    check sawDelayAboveMinimum
    check minimumDelayHits * 100 < BoundarySamples * MinBoundaryHitRatePct
