import chronos
import stream

template toFuture*[T](v: T): Future[T] =
  var fut = newFuture[T]()
  fut.complete(v)
  fut

proc appendNl*(): Through[seq[byte]] =
  proc append(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
    result = await item
    result.add(byte('\n'))

  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(abort: bool = false): Future[seq[byte]] {.closure.} =
      for item in i:
        yield append(item)

proc stripNl*(): Through[seq[byte]] =
  proc strip(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
    result = await item
    if result.len > 0 and result[^1] == byte('\n'):
      result.setLen(result.high)

  return proc(i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
    return iterator(abort: bool = false): Future[seq[byte]] {.closure.} =
      for item in i:
        yield strip(item)

proc cat*[T](srcs: seq[Source[T]]): Source[T] =
  return iterator(abort: bool = false): Future[T] =
    for src in srcs:
      for i in src(abort):
        yield i
