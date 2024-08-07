import chronos/futures, stew/results, chronos

proc waitForResult*[T](
    fut: Future[T], timeout: Duration
): Future[Result[T, string]] {.async.} =
  try:
    let val = await fut.wait(timeout)
    return Result[T, string].ok(val)
  except Exception as e:
    return Result[T, string].err(e.msg)
