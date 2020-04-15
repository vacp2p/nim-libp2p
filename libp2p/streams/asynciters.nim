import chronos
import stream

template toFuture*[T](v: T): Future[T] =
  var fut = newFuture[T]()
  fut.complete(v)
  fut

proc forEach*[T](iter: Source[T],
                 pred: proc(item: Future[T]):
                 Future[void] {.gcsafe.}) {.async.} =
  for i in iter:
    await pred(i)

proc collect*[T](iter: Source[T]): Future[seq[T]] =
  for i in iter:
    result.add(i)

proc map*[T, S](iter: Source[T],
                pred: proc(item: Future[T]): Future[S] {.gcsafe.}):
                Source[T] =
  return iterator(): Future[S] =
    for i in iter:
      yield pred(i)

proc filter*[T](iter: Source[T],
                pred: proc(item: Future[T]): Future[bool] {.gcsafe.}):
                Source[T] =
  return iterator(): Future[T] =
    proc next(item: Future[T]): Future[T] {.async.} =
      for i in iter:
        if not (await pred(i)):
            continue
        result = await i

    for i in iter:
      yield next(i)

proc zip*[T,S](i: Source[T],
               j: Source[S]):
               iterator(): Future[tuple[a: Future[T], b: Future[S]]] {.gcsafe.} =
  ## Iterates through both iterators at the same time, returning a tuple of
  ## both elements as long as neither of the iterators has finished.
  ##
  ## .. code-block:: nim
  ##   for x in zip(1..4, 20..24):
  ##     echo x
  return iterator(): Future[tuple[a: Future[T], b: Future[S]]] {.gcsafe.} =
    while true:
      let res = (i(), j())
      if finished(i) or finished(j):
        break
      yield res.toFuture

proc slice*[T](i: Source[T],
               first = 0, last = 0, step = 1): Source[T] =
  ## Yields every `step` item in `i` from index `first` to `last`.
  ##
  ## .. code-block:: nim
  ##   for i in slice(0..100, 10, 20)
  ##     echo i
  var pos = 0
  return iterator(): Future[T] {.gcsafe.} =
    for x in i:
      if pos > last:
        break
      elif pos >= first and (pos - first) mod step == 0:
        yield x
      inc pos

proc delete*[T](i: Source[T],
                first = 0, last = 0): Source[T] =
  ## Yields the items in `i` except for the ones between `first` and `last`.
  ##
  ## .. code-block:: nim
  ##   for x in delete(1..10, 4, 8):
  ##     echo x
  var pos = 0
  return iterator(): Future[T] {.gcsafe.} =
    for x in i:
      if pos notin first..last:
        yield x
      inc pos

proc foldl*[T,S](i: Source[T],
                 f: proc(x: Future[S], y: Future[T]): Future[S] {.gcsafe.},
                 y: Future[S] | S):
                 Future[S] =
  ## Folds the values as the iterator yields them, returning the accumulation.
  ##
  ## As the initial value of the accumulation `y` is used.
  ##
  ## .. code-block:: nim
  ##   echo foldl(1..10, proc(x,y: int): int = x + y, 0)
  when type(y) is Future:
    result = await y
  else:
    result = y.toFuture

  for x in i:
    result = f(result, x)

when isMainModule:
  import unittest, strutils

  suite "nimstreams":
    test "forEach":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          for i in @[1, 2, 3, 4, 5]:
            yield i.toFuture

        var count = 1
        await stream.forEach(
          proc(item: Future[int]): Future[void] {.async, gcsafe.} =
            check:
              count == await item
            count.inc())

        result = true

      check:
        waitFor(test()) == true

    test "map":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[char] {.closure, gcsafe.} =
          for i in @['a', 'b', 'c', 'd', 'e']:
            yield i.toFuture

        var items = @['A', 'B', 'C', 'D', 'E']
        var pos = 0
        await stream
        .map(
          proc(item: Future[char]): Future[char] {.async, gcsafe.} =
            result = (await item).toUpperAscii())
        .forEach(
          proc(item: Future[char]): Future[void] {.async, gcsafe.} =
            check:
              items[pos] == await item
            pos.inc())

        result = true

      check:
        waitFor(test()) == true

    test "filter not empty":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          for i in @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]:
            yield i.toFuture

        await stream
        .filter(
          proc (item: Future[int]): Future[bool] {.async, gcsafe.} =
            result = (await item) mod 2 == 0)
        .forEach(
          proc(item: Future[int]): Future[void] {.async.} =
            check:
              (await item) mod 2 == 0)
        result = true

      check:
        waitFor(test()) == true

    test "filter empty":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          discard

        await stream
        .filter(
          proc(item: Future[int]): Future[bool] {.async, gcsafe.} =
            discard)
        .forEach(
          proc(item: Future[int]): Future[void] {.async.} = discard)
        result = true

      check:
        waitFor(test()) == true

    test "zip":
      proc test(): Future[bool] {.async.} =
        var iterable1 = @[1, 2, 3, 4, 5]
        iterator stream1(): Future[int] {.closure, gcsafe.} =
          for i in iterable1:
            yield i.toFuture

        var iterable2 = @[6, 7, 8]
        iterator stream2(): Future[int] {.closure, gcsafe.} =
          for i in iterable2:
            yield i.toFuture

        var count = 0
        await stream1
        .zip(stream2)
        .forEach(
          proc(item: Future[(Future[int], Future[int])]):
            Future[void] {.async.} =
            var (a, b) = await item
            check:
              iterable1[count] == (await a)
              iterable2[count] == (await b)
            count.inc())

        result = true

      check:
        waitFor(test()) == true

    test "slice":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          for i in @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
            yield i.toFuture

        var count = 4
        await stream
        .slice(4, 8)
        .forEach(
          proc(item: Future[int]): Future[void] {.async.} =
            check:
              count == await item
            count.inc)
        result = true

      check:
        waitFor(test()) == true

    test "delete":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          for i in @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
            yield i.toFuture

        var count = 5
        await stream
        .delete(5, 9)
        .forEach(
          proc(item: Future[int]): Future[void] {.async.} =
            check:
              count != await item
            count.inc)

        result = count == 10

      check:
        waitFor(test()) == true

    test "foldl":
      proc test(): Future[bool] {.async.} =
        iterator stream(): Future[int] {.closure, gcsafe.} =
          for i in @[1, 2, 3, 4, 5]:
            yield i.toFuture

        var count = 1
        var res = await stream.foldl(
          proc(x: Future[int], y: Future[int]): Future[int] {.async, gcsafe.} =
            result = ((await x) + (await y)),
          0)

        result = true

      check:
        waitFor(test()) == true
