# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable delay strategy interface for the Mix Protocol.

import std/math
import bearssl/rand
import ./delay
export delay

type DelayStrategy* = ref object of RootObj ## Abstract interface for delay strategies.
  rng: ref HmacDrbgContext

method generateForEntry*(self: DelayStrategy): Delay {.base, gcsafe, raises: [].} =
  ## Generate delay value to encode in packet (called by sender/entry node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForEntry must be implemented by concrete delay strategy types"

method generateForIntermediate*(
    self: DelayStrategy, encodedDelay: Delay
): Delay {.base, gcsafe, raises: [].} =
  ## Generate actual delay from encoded value (called by intermediate node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForIntermediate must be implemented by concrete delay strategy types"

type NoSamplingDelayStrategy* = ref object of DelayStrategy
  ## Default strategy: generates random delays [0-2]ms, uses them directly.

proc new*(T: typedesc[NoSamplingDelayStrategy], rng: ref HmacDrbgContext): T =
  doAssert(rng != nil, "random is not set")
  T(rng: rng)

method generateForEntry*(self: NoSamplingDelayStrategy): Delay {.gcsafe, raises: [].} =
  self.rng[].generate(uint16) mod 3

method generateForIntermediate*(
    self: NoSamplingDelayStrategy, encodedDelay: Delay
): Delay {.gcsafe, raises: [].} =
  encodedDelay

const DefaultMeanDelay*: Delay = 100
const DefaultNegligibleProb* = 1e-6
  ## Probability below which the tail of the exponential distribution is
  ## excluded from the practical sampling window.
  ## Yields a maximum delay of mean * -ln(negligibleProb) ≈ mean * 13.8.
const DefaultMinimumDelay*: Delay = 0
  ## Optional lower bound for sampled delays. This is useful when auxiliary work
  ## such as proof generation runs in parallel with the delay timer and would
  ## otherwise collapse the lower tail into a predictable floor.
const DefaultSpamProtectionDelayFloor*: Delay = 100
  ## Recommended default lower bound when per-hop spam protection is enabled.
  ## Use `SpamProtectionDelayStrategy` to apply this floor explicitly.

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  ## Samples are drawn directly from the exponential distribution conditioned on
  ## the configured [minimumDelay, practicalMaxDelay] window. This preserves
  ## a smooth bounded distribution without fixed spikes at either bound.
  meanDelay: Delay
  negligibleProb: float64
  minimumDelay: Delay

type SpamProtectionDelayStrategy* = ref object of ExponentialDelayStrategy
  ## Recommended strategy when `MixProtocol` is configured with per-hop spam
  ## protection. Applies a non-zero minimum delay floor by default so proof
  ## generation time does not collapse short delays into a predictable spike.

proc new*(
    T: typedesc[ExponentialDelayStrategy],
    meanDelay: Delay = DefaultMeanDelay,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelay: Delay = DefaultMinimumDelay,
): T {.raises: [].} =
  doAssert(rng != nil, "random is not set")
  doAssert(
    negligibleProb > 0.0 and negligibleProb < 1.0, "negligibleProb must be in (0, 1)"
  )
  T(
    meanDelay: meanDelay,
    rng: rng,
    negligibleProb: negligibleProb,
    minimumDelay: minimumDelay,
  )

proc new*(
    T: typedesc[SpamProtectionDelayStrategy],
    meanDelay: Delay = DefaultMeanDelay,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelay: Delay = DefaultSpamProtectionDelayFloor,
): T {.raises: [].} =
  doAssert(rng != nil, "random is not set")
  doAssert(
    negligibleProb > 0.0 and negligibleProb < 1.0, "negligibleProb must be in (0, 1)"
  )
  T(
    meanDelay: meanDelay,
    rng: rng,
    negligibleProb: negligibleProb,
    minimumDelay: minimumDelay,
  )

proc sampleOpenUnitInterval(self: DelayStrategy): float64 {.inline, raises: [].} =
  const Float64MantissaBits = 53
  let rand53 = self.rng[].generate(uint64) shr (64 - Float64MantissaBits)
  (float64(rand53) + 0.5) / float64(1'u64 shl Float64MantissaBits)

proc practicalMaxDelay(meanDelay: Delay, negligibleProb: float64): float64 {.inline.} =
  min(-float64(meanDelay) * ln(negligibleProb), float64(high(Delay)))

proc sampleTruncatedExponential(
    self: DelayStrategy, meanDelay: Delay, minDelay, maxDelay: float64
): Delay {.inline, raises: [].} =
  let
    meanDelayF = float64(meanDelay)
    minBound = exp(-minDelay / meanDelayF)
    maxBound = exp(-maxDelay / meanDelayF)
    sample = self.sampleOpenUnitInterval()
    delayVal = -meanDelayF * ln(minBound - sample * (minBound - maxBound))
    boundedDelay = clamp(delayVal, minDelay, min(maxDelay, float64(high(Delay))))
  boundedDelay.uint16

method generateForEntry*(self: ExponentialDelayStrategy): Delay {.gcsafe, raises: [].} =
  self.meanDelay

method generateForIntermediate*(
    self: ExponentialDelayStrategy, encodedDelay: Delay
): Delay {.gcsafe, raises: [].} =
  ## Samples directly from the exponential distribution conditioned on the
  ## configured practical window. If the configured minimum delay already
  ## exceeds the practical maximum for the encoded mean, the configured minimum
  ## is returned as a deterministic fallback.
  if encodedDelay == NoDelay:
    return NoDelay

  let
    minDelay = float64(self.minimumDelay)
    maxDelay = practicalMaxDelay(encodedDelay, self.negligibleProb)

  if minDelay >= maxDelay:
    return self.minimumDelay

  self.sampleTruncatedExponential(encodedDelay, minDelay, maxDelay)
