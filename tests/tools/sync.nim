# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos

type WaitGroup* = ref object of RootObj
  ## A synchronization primitive that waits for a collection of 
  ## asynchronous tasks to finish.
  count: int
  fut: Future[void].Raising([])

proc newWaitGroup*(count: int): WaitGroup =
  doAssert(count >= 0, "WaitGroup count must be non negative number")
  let fut = Future[void].Raising([]).init("WaitGroup", {FutureFlag.OwnCancelSchedule})
  if count == 0:
    fut.complete()
  WaitGroup(count: count, fut: fut)

proc wait*(wg: WaitGroup): Future[void].Raising([CancelledError]) =
  return wg.fut.join()

proc wait*(wg: WaitGroup, timeout: Duration): Future[void] =
  let waitFut = wg.wait()
  return waitFut.wait(timeout)

proc done*(wg: WaitGroup) =
  if wg.fut.finished:
    return

  dec(wg.count)
  if wg.count == 0:
    wg.fut.complete()
