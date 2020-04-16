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
  Source*[T] = iterator(): Future[T] {.closure.}
  Through*[T] = proc(i: Source[T]): Source[T]
  Sink*[T] = proc(i: Source[T]): Future[void]
  Duplex*[T] = Source[T] | Sink[T]

  Stream*[T] = ref object of RootObj
    name*: string
    closed*: bool
    eof*: bool
    sourceImpl*: proc (s: Stream[T]): Source[T] {.gcsafe.}
    sinkImpl*: proc(s: Stream[T]): Sink[T] {.gcsafe.}

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

proc atEof*[T](s: Stream[T]): bool =
  s.eof

proc close*[T](s: Stream[T]) {.async.} =
  s.closed = true

template toFuture*[T](v: T): Future[T] =
  var fut = newFuture[T]()
  fut.complete(v)
  fut

template pipe*[T](s: Stream[T] | Source[T],
                  t: varargs[Through[T]]): Source[T] =
  var pipeline: Source[T]
  when s is Source[T]:
    pipeline = s
  elif s is Stream[T]:
    pipeline = s.source

  for i in t:
    pipeline = i(pipeline)

  pipeline

template pipe*[T](s: Stream[T] | Source[T],
                  t: varargs[Through[T]],
                  x: Stream[T] | Sink[T]): Future[void] =
  var pipeline = pipe(s, t)
  var terminal: Future[void]
  when x is Stream[T]:
    terminal = x.sink()(pipeline)
  elif x is Sink[T]:
    terminal = x(pipeline)

  terminal
