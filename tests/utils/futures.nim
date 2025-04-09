import chronos/futures, stew/results, chronos, sequtils

const
  DURATION_TIMEOUT* = 1.seconds
  DURATION_TIMEOUT_EXTENDED* = 1500.milliseconds

proc toOk(future: Future[void]): Result[void, FutureState] =
  return results.ok()

proc toOk[T](future: Future[T]): Result[T, FutureState] =
  return results.ok(future.read())

proc toResult*[T](future: Future[T]): Result[T, FutureState] =
  if future.cancelled():
    return results.err(Cancelled)
  elif future.finished():
    if future.failed():
      return results.err(Failed)
    else:
      return future.toOk()
  else:
    return results.err(Pending)

proc waitForResult*[T](
    future: Future[T], timeout = DURATION_TIMEOUT
): Future[Result[T, FutureState]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toResult()

proc waitForResults*[T](
    futures: seq[Future[T]], timeout = DURATION_TIMEOUT
): Future[seq[Result[T, FutureState]]] {.async.} =
  await sleepAsync(timeout)
  return futures.mapIt(it.toResult())
