import chronos
import stream

template toFuture*[T](v: T): Future[T] =
  var fut = newFuture[T]()
  fut.complete(v)
  fut

template toThrough*[T](s: Stream[T]): Through[T] =
  proc sinkit(i: Source[T]) {.async.} =
    await s.sink()(i)

  return proc(i: Source[T]): Source[T] =
    asyncCheck sinkit(i)
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
  pipe(s, x)


