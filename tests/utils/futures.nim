import chronos/futures, stew/results, chronos

const
  DURATION_TIMEOUT* = 1.seconds
  DURATION_TIMEOUT_EXTENDED* = 1500.milliseconds

proc toOk(future: Future[void]): Result[void, string] =
  return results.ok()

proc toOk[T](future: Future[T]): Result[T, string] =
  return results.ok(future.read())

proc toResult*[T](future: Future[T]): Result[T, string] =
  if future.cancelled():
    return results.err("Future cancelled/timed out.")
  elif future.finished():
    if not future.failed():
      return future.toOk()
    else:
      return results.err("Future finished but failed.")
  else:
    return results.err("Future still not finished.")

proc waitForResult*[T](
    future: Future[T], timeout = DURATION_TIMEOUT
): Future[Result[T, string]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toResult()

proc reset*[T](future: Future[T]): void =
  # Likely an incomplete reset, but good enough for testing purposes (for now)
  future.internalError = nil
  future.internalState = FutureState.Pending
