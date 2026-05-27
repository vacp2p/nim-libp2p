# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos

type AllFuturesFailedError* = object of CatchableError

proc anyCompleted*[T](
    futs: seq[T]
): Future[T] {.async: (raises: [AllFuturesFailedError, CancelledError]).} =
  ## Returns a future that will complete with the first future that completes.
  ## If all futures fail or futs is empty, the returned future will fail with AllFuturesFailedError.

  var requests = futs

  while true:
    try:
      var raceFut = await one(requests)
      if raceFut.completed:
        return raceFut
      requests.del(requests.find(raceFut))
    except ValueError as e:
      raise newException(
        AllFuturesFailedError, "None of the futures completed successfully: " & e.msg, e
      )
    except CancelledError as exc:
      raise exc
    except CatchableError:
      continue

template newFutureCompleted*[T](): auto =
  let fut = newFuture[T]()
  fut.complete()
  fut

template cancelAndWait*[T](futs: seq[T]): auto =
  var cancelFuts = newSeqOfCap[Future[void].Raising([])](futs.len)
  for fut in futs:
    cancelFuts.add(fut.cancelAndWait())
  allFutures(cancelFuts)

template cancelSoon*[T](futs: seq[T]) =
  for fut in futs:
    fut.cancelSoon()

proc allFuturesWaitOrTimeout*[Fut](
    futs: seq[Fut], timeout: Duration
) {.async: (raises: [CancelledError]).} =
  try:
    await futs.allFutures().wait(timeout)
  except AsyncTimeoutError:
    discard

template completeOnce*(fut: Future[void]) =
  ## Complete a future only if it is not already finished.
  if not fut.finished:
    fut.complete()

template completeOnce*[T](fut: Future[T], val: T) =
  ## Complete a future only if it is not already finished.
  if not fut.finished:
    fut.complete(val)
