# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import rng
import bearssl/rand
import bearssl/hash
import std/random

export Rng

type
  TestRng* = ref object of Rng
    hmacDrbgContext: ref HmacDrbgContextMock
    prngClass: PrngClass

  HmacDrbgContextMock* = object
    vtable: ptr PrngClass  # Mock VTable
    K: array[64, byte]    # Mock cryptographic key
    V: array[64, byte]    # Mock cryptographic state
    digestClass: ptr HashClass  # Point to a mock or dummy hash class

# Helper to easily cast to correct type
proc toMock(ctx: ptr ptr PrngClass): ptr HmacDrbgContextMock =
  return cast[ptr HmacDrbgContextMock](ctx[])

proc mockInit(ctx: ptr ptr PrngClass, params: pointer, seed: pointer, seedLen: uint) {.cdecl, noSideEffect, gcsafe.} =
  let mockCtx = toMock(ctx)
  # Initialize V with a simple pattern or seed data if available
  for i in 0..<len(mockCtx.V):
    mockCtx.V[i] = byte(i)  # or derive from `seed` if applicable

proc mockGenerate(ctx: ptr ptr PrngClass, `out`: pointer, len: uint) {.cdecl, noSideEffect, gcsafe.} =
  let mockCtx = toMock(ctx)
  if `out` != nil:
    let output = cast[ptr array[0..high(int), byte]](`out`)
    for i in 0..<int(len):
      # Use current state of V to compute next byte
      output[i] = byte((mockCtx.V[i mod len(mockCtx.V)] * 1664525'u32 + 1013904223'u32) shr 24)
      # Update V to ensure it changes for the next call
      mockCtx.V[i mod len(mockCtx.V)] = output[i]

proc mockUpdate(ctx: ptr ptr PrngClass, seed: pointer, seedLen: uint) {.cdecl, noSideEffect, gcsafe.} =
   # Update V based on seed
  let mockCtx = toMock(ctx)
  if seed != nil and seedLen > 0:
    let seedBytes = cast[ptr array[0..high(int), byte]](seed)
    for i in 0..<min(int(seedLen), len(mockCtx.V)):
      # Correctly dereference the byte at index i from seedBytes
      let currentSeedByte = seedBytes[i]  # Access ith byte from seedBytes
      mockCtx.V[i] = byte((mockCtx.V[i] + currentSeedByte) mod 256)

method shuffle*[T](
  rng: TestRng,
  x: var openArray[T]) =
  x

method generate*(rng: TestRng, v: var openArray[byte]) =
  for i in 0..<len(v):
    v[i] = rand(0..255).uint8

proc new*(
  T: typedesc[TestRng]): T =
  let t = T(
    hmacDrbgContext: HmacDrbgContextMock.new(),
    prngClass:
      PrngClass(
       contextSize: uint(sizeof(HmacDrbgContextMock)),
       init: mockInit,
       generate: mockGenerate,
       update: mockUpdate)
      )
  t.hmacDrbgContext.vtable = addr t.prngClass
  t.vtable = addr t.hmacDrbgContext.vtable
  t