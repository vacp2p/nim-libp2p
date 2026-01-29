# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable delay strategy interface for the Mix Protocol.

import std/math
import bearssl/rand
import ../../crypto/crypto

type DelayStrategy* = ref object of RootObj ## Abstract interface for delay strategies.
  rng: ref HmacDrbgContext

import results

method generateForEntry*(
    self: DelayStrategy
): Result[uint16, string] {.base, gcsafe, raises: [].} =
  ## Generate delay value to encode in packet (called by sender/entry node).

method generateForIntermediate*(
    self: DelayStrategy, encodedDelayMs: uint16
): uint16 {.base, gcsafe, raises: [].} =
  ## Generate actual delay from encoded value (called by intermediate node).
  ## implementation should return some default value in case of errors

type NoSamplingDelayStrategy* = ref object of DelayStrategy
  ## Default strategy: generates random delays [0-2]ms, uses them directly.

proc new*(T: typedesc[NoSamplingDelayStrategy], rng: ref HmacDrbgContext): T =
  T(rng: rng)

method generateForEntry*(
    self: NoSamplingDelayStrategy
): Result[uint16, string] {.gcsafe, raises: [].} =
  if self.rng.isNil:
    return err("RNG is nil")
  ok((self.rng[].generate(uint64) mod 3).uint16)

method generateForIntermediate*(
    self: NoSamplingDelayStrategy, encodedDelayMs: uint16
): uint16 {.gcsafe, raises: [].} =
  encodedDelayMs

const DefaultMeanDelayMs* = 100

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  meanDelayMs: uint16

proc new*(
    T: typedesc[ExponentialDelayStrategy],
    meanDelayMs: uint16 = DefaultMeanDelayMs,
    rng: ref HmacDrbgContext,
): T =
  T(meanDelayMs: meanDelayMs, rng: rng)

method generateForEntry*(
    self: ExponentialDelayStrategy
): Result[uint16, string] {.gcsafe, raises: [].} =
  ok(self.meanDelayMs)

method generateForIntermediate*(
    self: ExponentialDelayStrategy, meanDelayMs: uint16
): uint16 {.gcsafe, raises: [].} =
  ## Samples from exponential distribution: delay = -mean * ln(U)
  ## Fall back to no delay in case of errors
  if meanDelayMs == 0:
    return 0u16
  if self.rng.isNil:
    return 0u16
  let randVal = self.rng[].generate(uint64)
  let u = (float64(randVal) + 1.0) / (float64(high(uint64)) + 1.0)
  let delay = -float64(meanDelayMs) * ln(u)
  min(delay, float64(high(uint16))).uint16

proc exponentialDelayStrategy*(
    meanDelayMs: uint16 = DefaultMeanDelayMs, rng: ref HmacDrbgContext
): DelayStrategy =
  ## Returns ExponentialDelayStrategy (recommended per spec).
  ExponentialDelayStrategy.new(meanDelayMs, rng)
