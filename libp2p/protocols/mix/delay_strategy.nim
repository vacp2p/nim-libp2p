# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Pluggable delay strategy interface for the Mix Protocol.

import std/math
import bearssl/rand
import ../../crypto/crypto

type DelayStrategy* = ref object of RootObj ## Abstract interface for delay strategies.

import results

method generateDelay*(
    self: DelayStrategy, rng: ref HmacDrbgContext
): Result[uint16, string] {.base, gcsafe, raises: [].} =
  ## Generate delay value to encode in packet (called by sender).
  raiseAssert "generateDelay must be implemented by concrete delay strategy types"

method computeDelay*(
    self: DelayStrategy, rng: ref HmacDrbgContext, encodedDelayMs: uint16
): Result[uint16, string] {.base, gcsafe, raises: [].} =
  ## Compute actual delay from encoded value (called by intermediate node).
  raiseAssert "computeDelay must be implemented by concrete delay strategy types"

type NoSamplingDelayStrategy* = ref object of DelayStrategy
  ## Default strategy: generates random delays [0-2]ms, uses them directly.

proc new*(T: typedesc[NoSamplingDelayStrategy]): T =
  T()

method generateDelay*(
    self: NoSamplingDelayStrategy, rng: ref HmacDrbgContext
): Result[uint16, string] {.gcsafe, raises: [].} =
  if rng.isNil:
    return err("RNG is nil")
  ok((rng[].generate(uint64) mod 3).uint16)

method computeDelay*(
    self: NoSamplingDelayStrategy, rng: ref HmacDrbgContext, encodedDelayMs: uint16
): Result[uint16, string] {.gcsafe, raises: [].} =
  ok(encodedDelayMs)

const DefaultMeanDelayMs* = 100

type ExponentialDelayStrategy* = ref object of DelayStrategy
  ## Recommended strategy: encodes mean delay, samples from exponential distribution.
  meanDelayMs: uint16

proc new*(
    T: typedesc[ExponentialDelayStrategy], meanDelayMs: uint16 = DefaultMeanDelayMs
): T =
  T(meanDelayMs: meanDelayMs)

method generateDelay*(
    self: ExponentialDelayStrategy, rng: ref HmacDrbgContext
): Result[uint16, string] {.gcsafe, raises: [].} =
  ok(self.meanDelayMs)

method computeDelay*(
    self: ExponentialDelayStrategy, rng: ref HmacDrbgContext, meanDelayMs: uint16
): Result[uint16, string] {.gcsafe, raises: [].} =
  ## Samples from exponential distribution: delay = -mean * ln(U)
  if meanDelayMs == 0:
    return ok(0u16)
  if rng.isNil:
    return err("RNG is nil")
  let randVal = rng[].generate(uint64)
  let u = (float64(randVal) + 1.0) / (float64(high(uint64)) + 1.0)
  let delay = -float64(meanDelayMs) * ln(u)
  ok(min(delay, float64(high(uint16))).uint16)

proc defaultDelayStrategy*(): DelayStrategy =
  ## Returns NoSamplingDelayStrategy (backward compatible).
  NoSamplingDelayStrategy.new()

proc exponentialDelayStrategy*(
    meanDelayMs: uint16 = DefaultMeanDelayMs
): DelayStrategy =
  ## Returns ExponentialDelayStrategy (recommended per spec).
  ExponentialDelayStrategy.new(meanDelayMs)
