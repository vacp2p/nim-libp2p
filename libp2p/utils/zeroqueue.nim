# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/deques

type Chunk = ref object
  data: seq[byte]
  size: int
  start: int

template clone(c: Chunk): Chunk =
  Chunk(data: c.data, size: c.size, start: c.start)

template newChunk(b: sink seq[byte]): Chunk =
  Chunk(data: b, size: b.len, start: 0)

template len(c: Chunk): int =
  c.size - c.start

type ZeroQueue* = object
  # ZeroQueue is queue structure optimized for efficient pushing and popping of 
  # byte sequences `seq[byte]` (called chunks). This type is useful for streaming or buffering 
  # scenarios where chunks of binary data are accumulated and consumed incrementally.
  chunks: Deque[Chunk]
  queuedBytes: int64

proc clear*(q: var ZeroQueue) =
  q.chunks.clear()
  q.queuedBytes = 0

proc isEmpty*(q: ZeroQueue): bool =
  q.chunks.len() == 0

proc len*(q: ZeroQueue): int64 =
  q.queuedBytes

proc push*(q: var ZeroQueue, b: sink seq[byte]) =
  if b.len > 0:
    q.queuedBytes += b.len.int64
    q.chunks.addLast(newChunk(b))

proc popChunk(q: var ZeroQueue, count: int): Chunk {.inline.} =
  doAssert(count > 0, "count must be positive integer")
  var first = q.chunks.popFirst()

  # first chunk has up to requested count elements,
  # queue will return this chunk (chunk might have less then requested)
  if first.len() <= count:
    q.queuedBytes -= first.len().int64
    return first

  # first chunk has more elements then requested count, 
  # queue will return view of first count elements, leaving the rest in the queue
  var ret = first.clone()
  ret.size = ret.start + count
  first.start += count
  q.chunks.addFirst(first)
  q.queuedBytes -= count.int64
  return ret

proc consumeTo*(q: var ZeroQueue, pbytes: pointer, nbytes: int): int =
  var consumed = 0
  while consumed < nbytes and not q.isEmpty():
    let chunk = q.popChunk(nbytes - consumed)
    let dest = cast[pointer](cast[uint](pbytes) + consumed.uint)
    let offsetPtr = cast[ptr byte](cast[int](addr chunk.data[0]) + chunk.start)
    copyMem(dest, offsetPtr, chunk.len())
    consumed += chunk.len()

  return consumed

proc popChunkSeq*(q: var ZeroQueue, count: int): seq[byte] =
  doAssert(count >= 0, "count must be non-negative integer")
  if count == 0 or q.isEmpty:
    return @[]

  let chunk = q.popChunk(count)
  var dest = newSeqUninit[byte](chunk.len())
  let offsetPtr = cast[ptr byte](cast[int](addr chunk.data[0]) + chunk.start)
  copyMem(dest[0].addr, offsetPtr, chunk.len())

  return dest
