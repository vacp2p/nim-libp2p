# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[sets]
import ../../../libp2p/crypto/crypto
import ../../../libp2p/protocols/mix/delay_strategy
import ../../tools/[unittest, crypto]

const
  NumIterations = 100
  NumSamples = 10
  Tolerance = 0.2 # 20% tolerance for statistical tests

suite "DelayStrategy":
  test "NoSamplingDelayStrategy generateForEntry returns values in [0, 2]":
    let
      rng = rng()
      strategy = NoSamplingDelayStrategy.new(rng)

    for _ in 0 ..< NumIterations:
      let delay = strategy.generateForEntry().valueOr:
        raiseAssert error
      check delay <= 2

  test "NoSamplingDelayStrategy generateForIntermediate returns encoded value":
    let
      rng = rng()
      strategy = NoSamplingDelayStrategy.new(rng)

    check:
      strategy.generateForIntermediate(100) == 100
      strategy.generateForIntermediate(200) == 200

  test "ExponentialDelayStrategy generateForEntry returns configured mean":
    let rng = rng()

    check:
      ExponentialDelayStrategy.new(50, rng).generateForEntry().get() == 50
      ExponentialDelayStrategy.new(100, rng).generateForEntry().get() == 100

  test "ExponentialDelayStrategy generateForIntermediate returns 0 for mean 0":
    let
      strategy = ExponentialDelayStrategy.new(0, rng)
      rng = rng()

    check strategy.generateForIntermediate(0) == 0

  test "ExponentialDelayStrategy generateForIntermediate samples from exponential distribution":
    let
      rng = rng()
      strategy = ExponentialDelayStrategy.new(100, rng)
      meanDelayMs: uint16 = 100
      numSamples = 1000
    var sum: float64 = 0

    for _ in 0 ..< numSamples:
      let delay = strategy.generateForIntermediate(meanDelayMs)
      sum += float64(delay)

    let empiricalMean = sum / float64(numSamples)
    # Allow 20% tolerance for statistical variation
    check:
      empiricalMean > float64(meanDelayMs) * (1 - Tolerance)
      empiricalMean < float64(meanDelayMs) * (1 + Tolerance)

  test "ExponentialDelayStrategy produces variable delays":
    let
      rng = rng()
      strategy = ExponentialDelayStrategy.new(100, rng)
      meanDelayMs: uint16 = 100

    var delays = initHashSet[uint16]()
    for _ in 0 ..< NumSamples:
      let delay = strategy.generateForIntermediate(meanDelayMs)
      delays.incl(delay)

    check delays.len > NumSamples div 2
