## Nim-Libp2p
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils
import chronos, chronicles

# TODO: this should probably go in chronos

logScope:
  topics = "libp2p semaphore"

type
  AsyncSemaphore* = ref object of RootObj
    size*: int
    count*: int
    queue*: seq[Future[void]]

proc init*(T: type AsyncSemaphore, size: int): T =
  T(size: size, count: size)

proc tryAcquire*(s: AsyncSemaphore): bool =
  ## Attempts to acquire a resource, if successful
  ## returns true, otherwise false
  ##

  if s.count > 0 and s.queue.len == 0:
    s.count.dec
    trace "Acquired slot", available = s.count, queue = s.queue.len
    return true

proc acquire*(s: AsyncSemaphore): Future[void] =
  ## Acquire a resource and decrement the resource
  ## counter. If no more resources are available,
  ## the returned future will not complete until
  ## the resource count goes above 0 again.
  ##

  let fut = newFuture[void]("AsyncSemaphore.acquire")
  if s.tryAcquire():
    fut.complete()
    return fut

  s.queue.add(fut)
  s.count.dec
  trace "Queued slot", available = s.count, queue = s.queue.len
  return fut

proc release*(s: AsyncSemaphore) =
  ## Release a resource from the semaphore,
  ## by picking the first future from the queue
  ## and completing it and incrementing the
  ## internal resource count
  ##

  doAssert(s.count <= s.size)

  if s.count < s.size:
    trace "Releasing slot", available = s.count,
                            queue = s.queue.len

    if s.queue.len > 0:
      var fut = s.queue.pop()
      if not fut.finished():
        fut.complete()

    s.count.inc # increment the resource count
    trace "Released slot", available = s.count,
                           queue = s.queue.len
    return
