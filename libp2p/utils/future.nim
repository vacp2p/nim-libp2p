# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
    except ValueError:
      raise newException(
        AllFuturesFailedError, "None of the futures completed successfully"
      )
    except CancelledError as exc:
      raise exc
    except CatchableError:
      continue
