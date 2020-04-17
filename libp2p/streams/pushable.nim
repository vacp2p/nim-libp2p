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

proc close*[T](p: Pushable[T]) {.async.} =
  p.queue.clear()
  p.eof = true

proc push*[T](p: Pushable, item: T): Future[void] {.async.} =
  # TODO: just returning p.queue.put(item) future,
  # doesn't work reliably here. Might be a chronos
  # bug?
  await p.queue.put(item)

proc pushSource*[T](s: Stream[T]): Source[T] {.gcsafe.} =
  var p = Pushable[T](s)
  return iterator(): Future[T] =
    while not p.atEof:
      yield p.queue.get() # TODO: need to signal EOF on close here, possibly just cancel the future
    p.eof = true # we're EOF

proc init*[T](P: type[Pushable[T]], maxChunkSize = DefaultChunkSize): P =
  P(queue: newAsyncQueue[T](1),
    maxChunkSize: maxChunkSize,
    sourceImpl: pushSource,
    name: "Pushable")
