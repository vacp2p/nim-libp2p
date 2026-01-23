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
