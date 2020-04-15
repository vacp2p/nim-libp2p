## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

type
  Source*[T] = iterator(): Future[T] {.closure.}
  Through*[T] = proc(i: Source[T]): Source[T]
  Sink*[T] = proc(i: Source[T]): Future[void]
  Duplex*[T] = Source[T] | Sink[T]

  Stream* = ref object of RootObj
    isClosed*: bool

method source*(s: Stream): Source[seq[byte]] {.base.} =
  doAssert(false, "Not implemented!")

method sink*(s: Stream): Sink[seq[byte]] {.base.} =
  doAssert(false, "Not implemented!")

method atEof*(s: Stream): bool {.base.} =
  false

method close*(s: Stream) {.async, base.} =
  s.isClosed = true

method closed*(s: Stream): bool {.base.} =
  s.isClosed

proc duplex*[T](s: Stream): (Source[T], Sink[T]) =
  (s.source, s.sink)

iterator items*[T](i: Source[T]): Future[T] =
  ## Workaround semcheck, inlining everything allow proper iteration
  while true:
    var item = i()
    if i.finished:
      break
    yield item
