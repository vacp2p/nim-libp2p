## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles, stew/byteutils
import stream

logScope:
  topic = "WritableStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type
  Writable*[T] = ref object of Stream[T]
    eofTag*: T
    queue*: AsyncQueue[T]
    maxChunkSize: int

  ByteWritable* = Writable[seq[byte]]

proc close*[T](p: Writable[T]) {.async.} =
  await p.queue.put(p.eofTag)

proc write*[T](p: Writable[T], item: T): Future[void] =
  p.queue.put(item)

proc get[T](p: Writable[T]): Future[T] {.async.} =
  result = await p.queue.get()
  if result == p.eofTag:
    p.eof = true

proc writeSource*[T](s: Stream[T]): Source[T] {.gcsafe.} =
  var p = Writable[T](s)
  return iterator(abort: bool = false): Future[T] =
    if p.atEof:
      raise newStreamEofError()

    while not p.atEof and not abort:
      yield p.get()

proc init*[T](P: type[Writable[T]],
              maxChunkSize = DefaultChunkSize,
              eofTag: T): P =
  P(queue: newAsyncQueue[T](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: writeSource,
    eofTag: eofTag,
    name: "Writable")

proc init*(P: type[ByteWritable], maxChunkSize = DefaultChunkSize): P =
  P(queue: newAsyncQueue[seq[byte]](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: writeSource,
    eofTag: @[],
    name: "ByteWritable")
