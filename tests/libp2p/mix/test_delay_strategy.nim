# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/crypto/crypto
import ../../../libp2p/protocols/mix/delay_strategy
import ../../tools/[unittest]

suite "delay_strategy_tests":
  test "NoSamplingDelayStrategy generateDelay returns values in [0, 2]":
    let
      strategy = NoSamplingDelayStrategy.new()
      rng = newRng()

    for _ in 0 ..< 100:
      let delay = strategy.generateDelay(rng).valueOr:
        raiseAssert error
      check delay <= 2

  test "NoSamplingDelayStrategy computeDelay returns encoded value":
    let
      strategy = NoSamplingDelayStrategy.new()
      rng = newRng()

    let result100 = strategy.computeDelay(rng, 100).valueOr:
      raiseAssert error
    let result200 = strategy.computeDelay(rng, 200).valueOr:
      raiseAssert error
    check result100 == 100
    check result200 == 200

  test "ExponentialDelayStrategy generateDelay returns configured mean":
    let rng = newRng()

    let result50 = ExponentialDelayStrategy.new(50).generateDelay(rng).valueOr:
        raiseAssert error
    let result100 = ExponentialDelayStrategy.new(100).generateDelay(rng).valueOr:
        raiseAssert error
    check result50 == 50
    check result100 == 100

  test "ExponentialDelayStrategy computeDelay returns 0 for mean 0":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = newRng()

    let result0 = strategy.computeDelay(rng, 0).valueOr:
      raiseAssert error
    check result0 == 0

  test "ExponentialDelayStrategy computeDelay samples from exponential distribution":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = newRng()
      meanDelayMs: uint16 = 100
      numSamples = 1000

    var
      sum: float64 = 0
      samples: seq[uint16] = @[]

    for _ in 0 ..< numSamples:
      let delay = strategy.computeDelay(rng, meanDelayMs).valueOr:
        raiseAssert error
      samples.add(delay)
      sum += float64(delay)

    let empiricalMean = sum / float64(numSamples)
    # Allow 20% tolerance for statistical variation
    check:
      empiricalMean > float64(meanDelayMs) * 0.8
      empiricalMean < float64(meanDelayMs) * 1.2

  test "ExponentialDelayStrategy produces variable delays":
    let
      strategy = ExponentialDelayStrategy.new()
      rng = newRng()
      meanDelayMs: uint16 = 100

    var delays: seq[uint16] = @[]
    for _ in 0 ..< 10:
      let delay = strategy.computeDelay(rng, meanDelayMs).valueOr:
        raiseAssert error
      delays.add(delay)

    # Not all delays should be the same
    var allSame = true
    for i in 1 ..< delays.len:
      if delays[i] != delays[0]:
        allSame = false
        break
    check not allSame
