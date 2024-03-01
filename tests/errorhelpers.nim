import chronos

proc allFuturesThrowing*[F: FutureBase](args: varargs[F]): Future[void] =
  # This proc is only meant for use in tests / not suitable for general use.
  # - Swallowing errors arbitrarily instead of aggregating them is bad design
  # - It raises `CatchableError` instead of the union of the `futs` errors,
  #   inflating the caller's `raises` list unnecessarily. `macro` could fix it
  var futs: seq[F]
  for fut in args:
    futs &= fut
  proc call() {.async.} =
    var first: ref CatchableError = nil
    futs = await allFinished(futs)
    for fut in futs:
      if fut.failed:
        let err = fut.readError()
        if err of Defect:
          raise err
        else:
          if err of CancelledError:
            raise err
          if isNil(first):
            first = err
    if not isNil(first):
      raise first

  return call()
