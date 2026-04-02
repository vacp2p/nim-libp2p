# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable delay strategy interface for the Mix Protocol.

import std/math
import chronos
import bearssl/rand
import ../../crypto/crypto

type DelayStrategy* = ref object of RootObj ## Abstract interface for delay strategies.
  rng: ref HmacDrbgContext

method generateForEntry*(self: DelayStrategy): Duration {.base, gcsafe, raises: [].} =
  ## Generate delay value to encode in packet (called by sender/entry node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForEntry must be implemented by concrete delay strategy types"

method generateForIntermediate*(
    self: DelayStrategy, encodedDelay: Duration
): Duration {.base, gcsafe, raises: [].} =
  ## Generate actual delay from encoded value (called by intermediate node).
  ## implementation should return some default value in case of errors
  raiseAssert "generateForIntermediate must be implemented by concrete delay strategy types"

type NoSamplingDelayStrategy* = ref object of DelayStrategy
  ## Default strategy: generates random delays [0-2]ms, uses them directly.

proc new*(T: typedesc[NoSamplingDelayStrategy], rng: ref HmacDrbgContext): T =
  doAssert(rng != nil, "random is not set")
  T(rng: rng)

method generateForEntry*(
    self: NoSamplingDelayStrategy
): Duration {.gcsafe, raises: [].} =
  milliseconds(self.rng[].generate(uint16) mod 3)

method generateForIntermediate*(
    self: NoSamplingDelayStrategy, encodedDelay: Duration
): Duration {.gcsafe, raises: [].} =
  encodedDelay

const NoDelay*: Duration = milliseconds(0)
const DefaultMeanDelay*: Duration = milliseconds(100)
const DefaultNegligibleProb* = 1e-6
  ## Probability below which the tail of the exponential distribution is
  ## excluded from the practical sampling window.
  ## Yields a maximum delay of mean * -ln(negligibleProb) ≈ mean * 13.8.
const DefaultMinimumDelay*: Duration = milliseconds(0)
  ## Optional lower bound for sampled delays. This is useful when auxiliary work
  ## such as proof generation runs in parallel with the delay timer and would
  ## otherwise collapse the lower tail into a predictable floor.
const DefaultSpamProtectionDelayFloor*: Duration = milliseconds(100)
  ## Recommended default lower bound when per-hop spam protection is enabled.
  ## Use `SpamProtectionDelayStrategy` to apply this floor explicitly.

proc doAssertDelay*(delay: Duration) {.raises: [].} =
  ## Asserts that a delay value is valid for use in the Mix protocol.
  ## A valid delay must be non-negative and encodable in the 2-byte on-wire
  ## delay field (<=65535ms).
  doAssert(delay.milliseconds >= 0, "delay must be non-negative")
  doAssert(
    delay.milliseconds <= high(uint16).int,
    "delay must be encodable in 2 bytes (<=65535ms)",
  )

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  ## Samples are drawn directly from the exponential distribution conditioned on
  ## the configured [minimumDelay, practicalMaxDelay] window. This preserves
  ## a smooth bounded distribution without fixed spikes at either bound.
  meanDelay: Duration
  negligibleProb: float64
  minimumDelay: Duration

type SpamProtectionDelayStrategy* = ref object of ExponentialDelayStrategy
  ## Recommended strategy when `MixProtocol` is configured with per-hop spam
  ## protection. Applies a non-zero minimum delay floor by default so proof
  ## generation time does not collapse short delays into a predictable spike.

proc new*(
    T: typedesc[ExponentialDelayStrategy],
    meanDelay: Duration = DefaultMeanDelay,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelay: Duration = DefaultMinimumDelay,
): T {.raises: [].} =
  doAssert(rng != nil, "random is not set")
  doAssert(
    negligibleProb > 0.0 and negligibleProb < 1.0, "negligibleProb must be in (0, 1)"
  )
  doAssertDelay(meanDelay)
  doAssertDelay(minimumDelay)
  T(
    meanDelay: meanDelay,
    rng: rng,
    negligibleProb: negligibleProb,
    minimumDelay: minimumDelay,
  )

proc new*(
    T: typedesc[SpamProtectionDelayStrategy],
    meanDelay: Duration = DefaultMeanDelay,
    rng: ref HmacDrbgContext,
    negligibleProb: float64 = DefaultNegligibleProb,
    minimumDelay: Duration = DefaultSpamProtectionDelayFloor,
): T {.raises: [].} =
  doAssert(rng != nil, "random is not set")
  doAssert(
    negligibleProb > 0.0 and negligibleProb < 1.0, "negligibleProb must be in (0, 1)"
  )
  doAssertDelay(meanDelay)
  doAssertDelay(minimumDelay)
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

proc practicalMaxDelay(
    meanDelay: Duration, negligibleProb: float64
): Duration {.inline.} =
  let maxDelay = min(
    -float64(meanDelay.milliseconds) * ln(negligibleProb), float64(high(uint16))
  ).uint64
  return maxDelay.int.milliseconds

proc sampleTruncatedExponentialDelay(
    self: DelayStrategy, meanDelay: Duration, minDelay, maxDelay: Duration
): Duration {.inline, raises: [].} =
  let
    minDelayMs = minDelay.milliseconds.float64
    maxDelayMs = maxDelay.milliseconds.float64
    meanMs = float64(meanDelay.milliseconds)
    minBound = exp(-minDelayMs / meanMs)
    maxBound = exp(-maxDelayMs / meanMs)
    sample = self.sampleOpenUnitInterval()
    delay = -meanMs * ln(minBound - sample * (minBound - maxBound))
    boundedDelay = clamp(delay, minDelayMs, min(maxDelayMs, float64(high(uint16))))
  milliseconds(boundedDelay.int64)

method generateForEntry*(
    self: ExponentialDelayStrategy
): Duration {.gcsafe, raises: [].} =
  self.meanDelay

method generateForIntermediate*(
    self: ExponentialDelayStrategy, encodedDelay: Duration
): Duration {.gcsafe, raises: [].} =
  ## Samples directly from the exponential distribution conditioned on the
  ## configured practical window. If the configured minimum delay already
  ## exceeds the practical maximum for the encoded mean, the configured minimum
  ## is returned as a deterministic fallback.
  if encodedDelay == NoDelay:
    return encodedDelay

  let maxDelay = practicalMaxDelay(encodedDelay, self.negligibleProb)
  if self.minimumDelay >= maxDelay:
    return self.minimumDelay

  self.sampleTruncatedExponentialDelay(encodedDelay, self.minimumDelay, maxDelay)
