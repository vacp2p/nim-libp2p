## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import stream

const DefaultChunkSize* = 1 shl 20 # 1MB

type
  Pushable*[T] = ref object of Stream[T]
    queue: AsyncQueue[T]
    maxChunkSize: int
    eofFut: Future[T]
    eofTag: T

  BytePushable* = Pushable[seq[byte]]

proc close*[T](p: Pushable[T]) {.async.} =
  p.eofFut.complete(p.eofTag)
  p.eof = true

proc push*[T](p: Pushable[T], item: T): Future[void] {.async.} =
  await p.queue.put(item)

proc getOrCancel[T](p: Pushable[T]): Future[T] {.async.} =
  var res = await one(p.queue.get(), p.eofFut)
  result = await res

proc pushSource*[T](s: Stream[T]): Source[T] {.gcsafe.} =
  var p = Pushable[T](s)
  return iterator(): Future[T] =
    while not p.atEof:
      yield p.getOrCancel()
    p.eof = true # we're EOF

proc init*[T](P: type[Pushable[T]],
              maxChunkSize = DefaultChunkSize,
              eofTag: T): P =
  P(queue: newAsyncQueue[T](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: pushSource,
    name: "Pushable",
    eofFut: newFuture[T]())

proc init*(P: type[BytePushable], maxChunkSize = DefaultChunkSize): P =
  P(queue: newAsyncQueue[seq[byte]](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: pushSource,
    name: "BytePushable",
    eofFut: newFuture[seq[byte]](),
    eofTag: @[])
