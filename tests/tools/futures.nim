# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos/futures, chronos, sequtils

proc completedFuture*(): Future[void] =
  let f = newFuture[void]()
  f.complete()
  f

proc allFuturesDiscarding*(args: varargs[FutureBase]): Future[void] =
  # This proc is only meant for use in tests / not suitable for general use.
  # Swallowing errors arbitrarily instead of aggregating them is bad design
  # It raises `CatchableError` instead of the union of the `futs` errors,
  # inflating the caller's `raises` list unnecessarily. `macro` could fix it.
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

proc allFuturesDiscarding*[T](futs: varargs[Future[T]]): Future[void] =
  allFuturesDiscarding(futs.mapIt(FutureBase(it)))

proc allFuturesDiscarding*[T, E]( # https://github.com/nim-lang/Nim/issues/23432
    futs: varargs[InternalRaisesFuture[T, E]]
): Future[void] =
  allFuturesDiscarding(futs.mapIt(FutureBase(it)))
