import chronos

template withLock*(a: AsyncLock, body: untyped) =
  ## Acquires the given lock, executes the statements in body and
  ## releases the lock after the statements finish executing.
  await a.acquire()
  try:
    body
  finally:
    try:
      a.release()
    except AsyncLockError as exc:
      raiseAssert "AsyncLock release failed: " & exc.msg
