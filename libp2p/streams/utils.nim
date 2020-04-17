import chronos
import stream

template toFuture*[T](v: T): Future[T] =
  var fut = newFuture[T]()
  fut.complete(v)
  fut

proc toThrough*[T](s: Stream[T]): Through[T] {.inline.} =
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

proc appendNl*(): Through[seq[byte]] =
  proc append(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
    result = await item
    result.add(byte('\n'))

  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(): Future[seq[byte]] {.closure.} =
      for item in i:
        yield append(item)

proc stripNl*(): Through[seq[byte]] =
  proc strip(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
    result = await item
    if result.len > 0 and result[^1] == byte('\n'):
      result.setLen(result.high)

  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(): Future[seq[byte]] {.closure.} =
      for item in i:
        yield strip(item)
