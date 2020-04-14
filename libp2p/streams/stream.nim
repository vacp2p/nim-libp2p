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

  Stream*[T] = ref object of RootObj
    isClosed*: bool

  ByteStream* = Stream[seq[byte]]

proc source*[T](s: Stream[T]): Source[seq[byte]] =
  discard

proc sink*[T](s: Stream[T]): Sink[seq[byte]] =
  discard

proc atEof*[T](s: Stream[T]): bool =
  false

proc close*[T](s: Stream[T]) {.async.} =
  s.isClosed = true

proc closed*[T](s: Stream[T]): bool =
  s.isClosed

proc duplex*[T](s: Stream[T]): (Source[T], Sink[T]) =
  (s.source, s.sink)

iterator items*[T](i: Source[T]): Future[T] =
  ## Workaround semcheck, inlining everything allow proper iteration
  while true:
    var item = i()
    if i.finished:
      break
    yield item
