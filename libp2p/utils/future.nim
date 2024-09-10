# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import sequtils
import chronos

type AllFuturesFailedError* = object of CatchableError

proc anyCompleted*[T](futs: seq[Future[T]]): Future[Future[T]] {.async.} =
  ## Returns a future that will complete with the first future that completes.
  ## If all futures fail or futs is empty, the returned future will fail with AllFuturesFailedError.

  var requests = futs

  while true:
    if requests.len == 0:
      raise newException(
        AllFuturesFailedError, "None of the futures completed successfully"
      )

    var raceFut = await one(requests)
    if raceFut.completed:
      return raceFut

    let index = requests.find(raceFut)
    requests.del(index)

proc raceAndCancelPending*(
    futs: seq[SomeFuture]
): Future[void] {.async: (raises: [ValueError, CancelledError]).} =
  ## Executes a race between the provided sequence of futures.
  ## Cancels any remaining futures that have not yet completed.
  ##
  ## - `futs`: A sequence of futures to race.
  ##
  ## Raises:
  ## - `ValueError` if the sequence of futures is empty.
  ## - `CancelledError` if the operation is canceled.
  try:
    discard await race(futs)
  finally:
    await noCancel allFutures(futs.filterIt(not it.finished).mapIt(it.cancelAndWait))
