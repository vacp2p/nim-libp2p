# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

proc clear*(q: var ZeroQueue) =
  q.chunks.clear()

proc isEmpty*(q: ZeroQueue): bool =
  return q.chunks.len() == 0

proc len*(q: ZeroQueue): int64 =
  var l: int64
  for b in q.chunks.items():
    l += b.len()
  return l

proc push*(q: var ZeroQueue, b: sink seq[byte]) =
  if b.len > 0:
    q.chunks.addLast(newChunk(b))

proc popChunk(q: var ZeroQueue, count: int): Chunk {.inline.} =
  var first = q.chunks.popFirst()

  # first chunk has up to requested count elements,
  # queue will return this chunk (chunk might have less then requested)
  if first.len() <= count:
    return first

  # first chunk has more elements then requested count, 
  # queue will return view of first count elements, leaving the rest in the queue
  var ret = first.clone()
  ret.size = ret.start + count
  first.start += count
  q.chunks.addFirst(first)
  return ret

proc consumeTo*(q: var ZeroQueue, pbytes: pointer, nbytes: int): int =
  var consumed = 0
  while consumed < nbytes and not q.isEmpty():
    let chunk = q.popChunk(nbytes - consumed)
    let dest = cast[pointer](cast[ByteAddress](pbytes) + consumed)
    let offsetPtr = cast[ptr byte](cast[int](unsafeAddr chunk.data[0]) + chunk.start)
    copyMem(dest, offsetPtr, chunk.len())
    consumed += chunk.len()

  return consumed

proc popChunkSeq*(q: var ZeroQueue, count: int): seq[byte] =
  if q.isEmpty:
    return @[]

  let chunk = q.popChunk(count)
  var dest = newSeqUninitialized[byte](chunk.len())
  let offsetPtr = cast[ptr byte](cast[int](unsafeAddr chunk.data[0]) + chunk.start)
  copyMem(dest[0].addr, offsetPtr, chunk.len())

  return dest
