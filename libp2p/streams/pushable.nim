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
  topic = "PushableStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type
  Pushable*[T] = ref object of Stream[T]
    queue*: AsyncQueue[T]
    maxChunkSize: int

  BytePushable* = Pushable[seq[byte]]

proc close*[T](p: Pushable[T]) {.async.} =
  await p.queue.put(p.eofTag)

proc push*[T](p: Pushable[T], item: T): Future[void] =
  p.queue.put(item)

proc get[T](p: Pushable[T]): Future[T] {.async.} =
  result = await p.queue.get()
  if result == p.eofTag:
    p.eof = true

proc pushSource*[T](s: Stream[T]): Source[T] {.gcsafe.} =
  var p = Pushable[T](s)
  return iterator(): Future[T] =
    if p.atEof:
      raise newStreamEofError()

    while not p.atEof:
      yield p.get()

proc init*[T](P: type[Pushable[T]],
              maxChunkSize = DefaultChunkSize,
              eofTag: T): P =
  P(queue: newAsyncQueue[T](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: pushSource,
    eofTag: eofTag,
    name: "Pushable")

proc init*(P: type[BytePushable], maxChunkSize = DefaultChunkSize): P =
  P(queue: newAsyncQueue[seq[byte]](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: pushSource,
    name: "BytePushable",
    eofTag: @[])
