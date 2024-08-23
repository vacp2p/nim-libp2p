import chronos/futures, stew/results, chronos

proc waitForResult*[T](
    fut: Future[T], timeout: Duration = 1.seconds
): Future[Result[T, string]] {.async.} =
  try:
    let val = await fut.wait(timeout)
    return Result[T, string].ok(val)
  except Exception as e:
    return Result[T, string].err(e.msg)

proc waitForResult*(
    fut: Future[void], timeout: Duration = 1.seconds
): Future[Result[void, string]] {.async.} =
  try:
    await fut.wait(timeout)
    return Result[void, string].ok()
  except Exception as e:
    return Result[void, string].err(e.msg)
