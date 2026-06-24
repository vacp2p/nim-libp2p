# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
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

proc trackFut*[T](futs: var seq[T], fut: T) =
  ## Prune finished futures, then take ownership of `fut` for later teardown.
  futs.keepItIf(not it.finished())
  futs.add(fut)

proc allFuturesWaitOrTimeout*[Fut](
    futs: seq[Fut], timeout: Duration
) {.async: (raises: [CancelledError]).} =
  try:
    await futs.allFutures().wait(timeout)
  except AsyncTimeoutError:
    discard

template completeOnce*(fut: auto) =
  ## Complete a future only if it is not already finished.
  if not fut.finished:
    fut.complete()

template completeOnce*(fut: auto, val: auto) =
  ## Complete a future only if it is not already finished.
  if not fut.finished:
    fut.complete(val)

proc collectCompleted*[T, E](
    futs: seq[InternalRaisesFuture[T, E]], timeout: chronos.Duration
): Future[seq[T]] {.async: (raises: [CancelledError]).} =
  ## Wait up to `timeout`; collect only successfully completed futures.
  ## Ignore results from futures throwing errors
  try:
    await futs.allFutures().wait(timeout)
  except AsyncTimeoutError:
    # Some futures didn’t finish in time, ignore
    discard

  # Collect only successful results
  return futs.filterIt(it.completed()).mapIt(it.value())

proc waitForTCPServer*(
    taddr: TransportAddress,
    retries: int = 20,
    delay: chronos.Duration = 500.milliseconds,
): Future[bool] {.async.} =
  for i in 0 ..< retries:
    try:
      let conn = await connect(taddr)
      await conn.closeWait()
      return true
    except OSError:
      discard
    except TransportOsError:
      discard
    await sleepAsync(delay)
  return false
