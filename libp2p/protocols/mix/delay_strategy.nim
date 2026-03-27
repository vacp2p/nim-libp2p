# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable delay strategy interface for the Mix Protocol.

import std/math
import bearssl/rand
import ../../crypto/crypto

type DelayStrategy* = ref object of RootObj ## Abstract interface for delay strategies.
  rng: ref HmacDrbgContext

method generateForEntry*(self: DelayStrategy): uint16 {.base, gcsafe, raises: [].} =
  ## Generate delay value to encode in packet (called by sender/entry node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForEntry must be implemented by concrete delay strategy types"

method generateForIntermediate*(
    self: DelayStrategy, encodedDelayMs: uint16
): uint16 {.base, gcsafe, raises: [].} =
  ## Generate actual delay from encoded value (called by intermediate node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForIntermediate must be implemented by concrete delay strategy types"

type NoSamplingDelayStrategy* = ref object of DelayStrategy
  ## Default strategy: generates random delays [0-2]ms, uses them directly.

proc new*(T: typedesc[NoSamplingDelayStrategy], rng: ref HmacDrbgContext): T =
  doAssert(rng != nil, "random is not set")
  T(rng: rng)

method generateForEntry*(self: NoSamplingDelayStrategy): uint16 {.gcsafe, raises: [].} =
  self.rng[].generate(uint16) mod 3

method generateForIntermediate*(
    self: NoSamplingDelayStrategy, encodedDelayMs: uint16
): uint16 {.gcsafe, raises: [].} =
  encodedDelayMs

const DefaultMeanDelayMs* = 100
const DefaultNegligibleProb* = 1e-6
  ## Probability below which the tail of the exponential distribution is rejected
  ## and resampled.
  ## Yields a maximum delay of mean * -ln(negligibleProb) ≈ mean * 13.8.
const DefaultMinimumDelayMs* = 0
  ## Optional lower bound for sampled delays. This is useful when auxiliary work
  ## such as proof generation runs in parallel with the delay timer and would
  ## otherwise collapse the lower tail into a predictable floor.

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  ## Samples outside the configured [minimumDelayMs, practicalMaxDelayMs] window
  ## are rejected and resampled to preserve a smooth distribution without fixed
  ## spikes at either bound.
  meanDelayMs: uint16
  negligibleProb: float64
  minimumDelayMs: uint16

proc new*(
    T: typedesc[ExponentialDelayStrategy],
    meanDelayMs: uint16 = DefaultMeanDelayMs,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelayMs: uint16 = DefaultMinimumDelayMs,
): T {.raises: [].} =
  doAssert(rng != nil, "random is not set")
  doAssert(
    negligibleProb > 0.0 and negligibleProb < 1.0, "negligibleProb must be in (0, 1)"
  )
  T(
    meanDelayMs: meanDelayMs,
    rng: rng,
    negligibleProb: negligibleProb,
    minimumDelayMs: minimumDelayMs,
  )

proc minimumDelayMs*(self: ExponentialDelayStrategy): uint16 {.inline, raises: [].} =
  self.minimumDelayMs

proc setMinimumDelayMs*(
    self: ExponentialDelayStrategy, minimumDelayMs: uint16
) {.inline, raises: [].} =
  self.minimumDelayMs = minimumDelayMs

proc sampleOpenUnitInterval(self: DelayStrategy): float64 {.inline.} =
  let randVal = self.rng[].generate(uint64)
  (float64(randVal) + 1.0) / (float64(high(uint64)) + 1.0)

proc practicalMaxDelayMs(
    meanDelayMs: uint16, negligibleProb: float64
): float64 {.inline.} =
  min(-float64(meanDelayMs) * ln(negligibleProb), float64(high(uint16)))

method generateForEntry*(
    self: ExponentialDelayStrategy
): uint16 {.gcsafe, raises: [].} =
  self.meanDelayMs

method generateForIntermediate*(
    self: ExponentialDelayStrategy, meanDelayMs: uint16
): uint16 {.gcsafe, raises: [].} =
  ## Samples from an exponential distribution and rejection-samples values that
  ## fall outside the configured practical window.
  if meanDelayMs == 0:
    return 0u16

  let
    minDelayMs = float64(self.minimumDelayMs)
    maxDelayMs = practicalMaxDelayMs(meanDelayMs, self.negligibleProb)

  if minDelayMs >= maxDelayMs:
    return maxDelayMs.uint16

  while true:
    let delay = -float64(meanDelayMs) * ln(self.sampleOpenUnitInterval())
    if delay < minDelayMs or delay > maxDelayMs:
      continue
    return delay.uint16
