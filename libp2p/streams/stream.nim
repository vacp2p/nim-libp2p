## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

# TODO: Rework without methods

type
  StreamEofError = object of CatchableError

  Source*[T] = iterator(): Future[T] {.closure.}
  Through*[T] = proc(i: Source[T]): Source[T]
  Sink*[T] = proc(i: Source[T]): Future[void]
  Duplex*[T] = Source[T] | Sink[T]

  Stream*[T] = ref object of RootObj
    name*: string
    eof*: bool
    sourceImpl*: proc (s: Stream[T]): Source[T] {.gcsafe.}
    sinkImpl*: proc(s: Stream[T]): Sink[T] {.gcsafe.}
    eofTag*: T

proc newStreamEofError*(): ref StreamEofError =
  raise newException(StreamEofError, "Stream at EOF!")

iterator items*[T](i: Source[T]): Future[T] =
  while true:
    var item = i()
    if i.finished:
      break
    yield item

proc source*[T](s: Stream[T]): Source[T] =
  if not isNil(s.sourceImpl):
    return s.sourceImpl(s)

proc sink*[T](s: Stream[T]): Sink[T] =
  if not isNil(s.sinkImpl):
    return s.sinkImpl(s)

proc atEof*[T; S: Stream[T]](s: S): bool =
  s.eof

proc close*[T; S: Stream[T]](s: S) {.async.} =
  # close is called externally
  s.eof = true
