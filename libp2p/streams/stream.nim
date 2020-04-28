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
  StreamEofError = object of CatchableError

  Source*[T] = iterator(abort: bool = false): Future[T]
  Through*[T] = proc(i: Source[T]): Source[T]
  Sink*[T] = proc(i: Source[T]): Future[void]
  Duplex*[T] = Source[T] | Sink[T]

  Stream*[T] = ref object of RootObj
    eof*: bool
    sourceImpl*: proc (s: Stream[T]): Source[T] {.gcsafe.}
    sinkImpl*: proc(s: Stream[T]): Sink[T] {.gcsafe.}
    name*: string

proc newStreamEofError*(): ref StreamEofError =
  raise newException(StreamEofError, "Stream at EOF!")

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

proc init*[T](S: type Stream[T], sc: Source[T]): Stream[T] {.inline.} =
  proc source(): Source[T] # forward declaration
  var stream = Stream[T](sourceImpl: source)

  proc source(): Source[T] =
    return iterator(abort: bool = false) =
      for i in sc(stream.atEof):
        yield i

  return stream

proc init*[T](S: type Stream[T], sk: Sink[T]): Stream[T] {.inline.} =
  proc sink(source: Source[T]): Future[T] #forward declaration
  var stream = Stream(sinkImpl: proc() = sk(sink()))

  proc sink(source: Source[T]): Future[T] {.async.} =
    for i in source(stream.atEof):
      yield await i

  return stream

proc init*[T](S: type Stream[T],
              sc: Source[T],
              sk: Sink[T]): Stream[T] {.inline.} =

  Stream[T](
    sourceImpl:
      proc(s: Stream[T]): Source[T] =
        return iterator(abort: bool = false): Future[T] =
          for i in sc(s.atEof):
            yield i
    ,
    sinkImpl:
      proc(s: Stream[T]): Sink[T] =
        return proc(src: Source[T]): Future[void] =
          iterator wrapper(abort: bool = false): Future[T] =
            for i in src(s.atEof):
              yield i

          return sk(wrapper)
  )

iterator items*[T](s: Stream[T]): Future[T] {.inline.} =
  var i = s.source()
  while true:
    var item = i()
    if i.finished:
      break
    yield item

iterator items*[T](i: Source[T]): Future[T] {.inline.} =
  while true:
    var item = i()
    if i.finished:
      break
    yield item

proc toDuplex*[T](s: Stream[T]): Through[T] {.inline.} =
  proc sinkit(i: Source[T]) {.async.} =
    await s.sink()(i)

  return proc(i: Source[T]): Source[T] =
    asyncCheck sinkit(i) # TODO: remove asyncCheck
    s.source()

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
                  x: Stream[T] | Sink[T]): Future[void] =
  var pipeline: Source[T]
  when s is Source[T]:
    pipeline = s
  elif s is Stream[T]:
    pipeline = s.source

  var terminal: Future[void]
  when x is Stream[T]:
    terminal = x.sink()(pipeline)
  elif x is Sink[T]:
    terminal = x(pipeline)

  terminal

template pipe*[T](s: Stream[T] | Source[T],
                  t: varargs[Through[T]],
                  x: Stream[T] | Sink[T]): Future[void] =
  var pipeline = pipe(s, t)
  pipe(pipeline, x)
