import chronos/futures, results, chronos, sequtils

const
  DURATION_TIMEOUT* = 1.seconds
  DURATION_TIMEOUT_EXTENDED* = 1500.milliseconds

type FutureStateWrapper*[T] = object
  future: Future[T]
  state: FutureState
  when T is void:
    discard
  else:
    value: T

proc isPending*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Pending

proc isCompleted*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Completed

proc isCompleted*[T](wrapper: FutureStateWrapper[T], expectedValue: T): bool =
  when T is void:
    wrapper.state == Completed
  else:
    wrapper.state == Completed and wrapper.value == expectedValue

proc isCancelled*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Cancelled

proc isFailed*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Failed

proc toState*[T](future: Future[T]): FutureStateWrapper[T] =
  var wrapper: FutureStateWrapper[T]
  wrapper.future = future

  if future.cancelled():
    wrapper.state = Cancelled
  elif future.finished():
    if future.failed():
      wrapper.state = Failed
    else:
      wrapper.state = Completed
      when T isnot void:
        wrapper.value = future.read()
  else:
    wrapper.state = Pending

  return wrapper

proc waitForState*[T](
    future: Future[T], timeout = DURATION_TIMEOUT
): Future[FutureStateWrapper[T]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toState()

proc waitForStates*[T](
    futures: seq[Future[T]], timeout = DURATION_TIMEOUT
): Future[seq[FutureStateWrapper[T]]] {.async.} =
  await sleepAsync(timeout)
  return futures.mapIt(it.toState())

proc completedFuture*(): Future[void] =
  let f = newFuture[void]()
  f.complete()
  f

proc allFuturesThrowing*(args: varargs[FutureBase]): Future[void] =
  # This proc is only meant for use in tests / not suitable for general use.
  # - Swallowing errors arbitrarily instead of aggregating them is bad design
  # - It raises `CatchableError` instead of the union of the `futs` errors,
  #   inflating the caller's `raises` list unnecessarily. `macro` could fix it
  let futs = @args
  (
    proc() {.async: (raises: [CatchableError]).} =
      await allFutures(futs)
      var firstErr: ref CatchableError
      for fut in futs:
        if fut.failed:
          let err = fut.error()
          if err of CancelledError:
            raise err
          if firstErr == nil:
            firstErr = err
      if firstErr != nil:
        raise firstErr
  )()

proc allFuturesThrowing*[T](futs: varargs[Future[T]]): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))

proc allFuturesThrowing*[T, E]( # https://github.com/nim-lang/Nim/issues/23432
    futs: varargs[InternalRaisesFuture[T, E]]
): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))