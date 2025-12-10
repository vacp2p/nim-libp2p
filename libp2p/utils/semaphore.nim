# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.warning[UnusedImport]: off.}
import chronos

# DO NOT MODIFY THIS CODE!!!
# This code is copy-paste from: https://github.com/status-im/nim-chronos/pull/586/files
# It must be the same untill new version on chronos is released.

when not declared(chronos.AsyncSemaphore):
  import std/deques

  type AsyncSemaphore* = ref object of RootObj
    ## A semaphore manages an internal number of available slots which is decremented 
    ## by each ``acquire()`` call and incremented by each ``release()`` call. 
    ## The available slots can never go below zero; when ``acquire()`` finds that it is
    ## zero, it blocks, waiting until some other task calls ``release()``.
    ##
    ## The ``size`` argument gives the initial value for the available slots
    ## counter; it defaults to ``1``. If the value given is less than 1,
    ## ``AssertionDefect`` is raised.
    size: int
    availableSlots: int
    waiters: Deque[Future[void].Raising([CancelledError])]

  type AsyncSemaphoreError* = object of AsyncError

  proc newAsyncSemaphore*(size: int = 1): AsyncSemaphore =
    ## Creates a new asynchronous bounded semaphore ``AsyncSemaphore`` with
    ## internal available slots set to ``size``.
    doAssert(size > 0, "AsyncSemaphore initial size must be bigger then 0")
    AsyncSemaphore(
      size: size,
      availableSlots: size,
      waiters: initDeque[Future[void].Raising([CancelledError])](),
    )

  proc availableSlots*(s: AsyncSemaphore): int =
    return s.availableSlots

  proc tryAcquire*(s: AsyncSemaphore): bool =
    ## Attempts to acquire a resource, if successful returns true, otherwise false.

    if s.availableSlots > 0:
      s.availableSlots.dec
      true
    else:
      false

  proc acquire*(
      s: AsyncSemaphore
  ): Future[void] {.async: (raises: [CancelledError], raw: true).} =
    ## Acquire a resource and decrement the resource counter. 
    ## If no more resources are available, the returned future 
    ## will not complete until the resource count goes above 0.

    let fut = newFuture[void]("AsyncSemaphore.acquire")
    if s.tryAcquire():
      fut.complete()
      return fut

    s.waiters.addLast(fut)

    return fut

  proc release*(s: AsyncSemaphore) {.raises: [AsyncSemaphoreError].} =
    ## Release a resource from the semaphore,
    ## by picking the first future from waiters queue
    ## and completing it and incrementing the
    ## internal resource count.

    if s.availableSlots == s.size:
      raise newException(AsyncSemaphoreError, "release called without acquire")

    s.availableSlots.inc
    while s.waiters.len > 0:
      var fut = s.waiters.popFirst()
      if not fut.finished():
        s.availableSlots.dec
        fut.complete()
        break

else:
  # this hack fixes "unsed imports" errors, when this file is imported
  # but chornos has AsyncSemaphore defined.
  export chronos.AsyncSemaphore
