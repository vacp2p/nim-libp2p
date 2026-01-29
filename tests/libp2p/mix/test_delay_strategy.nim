# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import ../../../libp2p/crypto/crypto
import ../../../libp2p/protocols/mix/delay_strategy
import ../../tools/[unittest, crypto]

const
  NumIterations = 100
  NumSamples = 10
  Tolerance = 0.2 # 20% tolerance for statistical tests

suite "delay_strategy_tests":
  test "NoSamplingDelayStrategy generateDelay returns values in [0, 2]":
    let
      strategy = NoSamplingDelayStrategy.new()
      rng = rng()

    for _ in 0 ..< NumIterations:
      let delay = strategy.generateDelay(rng).valueOr:
        raiseAssert error
      check delay <= 2

  test "NoSamplingDelayStrategy computeDelay returns encoded value":
    let
      strategy = NoSamplingDelayStrategy.new()
      rng = rng()

    check:
      strategy.computeDelay(rng, 100).get() == 100
      strategy.computeDelay(rng, 200).get() == 200

  test "ExponentialDelayStrategy generateDelay returns configured mean":
    let rng = rng()

    check:
      ExponentialDelayStrategy.new(50).generateDelay(rng).get() == 50
      ExponentialDelayStrategy.new(100).generateDelay(rng).get() == 100

  test "ExponentialDelayStrategy computeDelay returns 0 for mean 0":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = rng()

    check strategy.computeDelay(rng, 0).get() == 0

  test "ExponentialDelayStrategy computeDelay samples from exponential distribution":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = rng()
      meanDelayMs: uint16 = 100
      numSamples = 1000

    var
      sum: float64 = 0
      samples: seq[uint16] = @[]

    for _ in 0 ..< numSamples:
      let delay = strategy.computeDelay(rng, meanDelayMs).get()
      samples.add(delay)
      sum += float64(delay)

    let empiricalMean = sum / float64(numSamples)
    # Allow 20% tolerance for statistical variation
    check:
      empiricalMean > float64(meanDelayMs) * (1 - Tolerance)
      empiricalMean < float64(meanDelayMs) * (1 + Tolerance)

  test "ExponentialDelayStrategy produces variable delays":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = rng()
      meanDelayMs: uint16 = 100

    var delays: seq[uint16] = @[]
    for _ in 0 ..< NumSamples:
      let delay = strategy.computeDelay(rng, meanDelayMs).get()
      delays.add(delay)

    check delays.anyIt(it != delays[0])
