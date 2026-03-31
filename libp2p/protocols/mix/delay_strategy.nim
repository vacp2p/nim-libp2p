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
  ## Probability below which the tail of the exponential distribution is
  ## excluded from the practical sampling window.
  ## Yields a maximum delay of mean * -ln(negligibleProb) ≈ mean * 13.8.
const DefaultMinimumDelayMs* = 0
  ## Optional lower bound for sampled delays. This is useful when auxiliary work
  ## such as proof generation runs in parallel with the delay timer and would
  ## otherwise collapse the lower tail into a predictable floor.
const DefaultSpamProtectionDelayFloorMs* = 100'u16
  ## Recommended default lower bound when per-hop spam protection is enabled.
  ## Use `SpamProtectionDelayStrategy` to apply this floor explicitly.

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  ## Samples are drawn directly from the exponential distribution conditioned on
  ## the configured [minimumDelayMs, practicalMaxDelayMs] window. This preserves
  ## a smooth bounded distribution without fixed spikes at either bound.
  meanDelayMs: uint16
  negligibleProb: float64
  minimumDelayMs: uint16

type SpamProtectionDelayStrategy* = ref object of ExponentialDelayStrategy
  ## Recommended strategy when `MixProtocol` is configured with per-hop spam
  ## protection. Applies a non-zero minimum delay floor by default so proof
  ## generation time does not collapse short delays into a predictable spike.

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

proc new*(
    T: typedesc[SpamProtectionDelayStrategy],
    meanDelayMs: uint16 = DefaultMeanDelayMs,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelayMs: uint16 = DefaultSpamProtectionDelayFloorMs,
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

proc sampleOpenUnitInterval(self: DelayStrategy): float64 {.inline, raises: [].} =
  const Float64MantissaBits = 53
  let rand53 = self.rng[].generate(uint64) shr (64 - Float64MantissaBits)
  (float64(rand53) + 0.5) / float64(1'u64 shl Float64MantissaBits)

proc practicalMaxDelayMs(
    meanDelayMs: uint16, negligibleProb: float64
): float64 {.inline.} =
  min(-float64(meanDelayMs) * ln(negligibleProb), float64(high(uint16)))

proc sampleTruncatedExponentialDelayMs(
    self: DelayStrategy, meanDelayMs: uint16, minDelayMs, maxDelayMs: float64
): uint16 {.inline, raises: [].} =
  let
    meanDelay = float64(meanDelayMs)
    minBound = exp(-minDelayMs / meanDelay)
    maxBound = exp(-maxDelayMs / meanDelay)
    sample = self.sampleOpenUnitInterval()
    delay = -meanDelay * ln(minBound - sample * (minBound - maxBound))
    boundedDelay = clamp(delay, minDelayMs, min(maxDelayMs, float64(high(uint16))))
  boundedDelay.uint16

method generateForEntry*(
    self: ExponentialDelayStrategy
): uint16 {.gcsafe, raises: [].} =
  self.meanDelayMs

method generateForIntermediate*(
    self: ExponentialDelayStrategy, encodedDelayMs: uint16
): uint16 {.gcsafe, raises: [].} =
  ## Samples directly from the exponential distribution conditioned on the
  ## configured practical window. If the configured minimum delay already
  ## exceeds the practical maximum for the encoded mean, the configured minimum
  ## is returned as a deterministic fallback.
  if encodedDelayMs == 0:
    return 0u16

  let
    minDelayMs = float64(self.minimumDelayMs)
    maxDelayMs = practicalMaxDelayMs(encodedDelayMs, self.negligibleProb)

  if minDelayMs >= maxDelayMs:
    return self.minimumDelayMs

  self.sampleTruncatedExponentialDelayMs(encodedDelayMs, minDelayMs, maxDelayMs)
