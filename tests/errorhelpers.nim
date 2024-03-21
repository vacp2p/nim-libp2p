import
  std/sequtils,
  chronos

proc allFuturesThrowing*(args: varargs[FutureBase]): Future[void] =
  # This proc is only meant for use in tests / not suitable for general use.
  # - Swallowing errors arbitrarily instead of aggregating them is bad design
  # - It raises `CatchableError` instead of the union of the `futs` errors,
  #   inflating the caller's `raises` list unnecessarily. `macro` could fix it
  let futs = @args
  (proc() {.async: (raises: [CatchableError]).} =
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
      raise firstErr)()

proc allFuturesThrowing*[T](futs: varargs[Future[T]]): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))

proc allFuturesThrowing*[T, E](  # https://github.com/nim-lang/Nim/issues/23432
    futs: varargs[InternalRaisesFuture[T, E]]): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))
