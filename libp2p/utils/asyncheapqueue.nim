# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/heapqueue
import chronos

type AsyncHeapQueue*[T] = ref object
  ## Unbounded async min-heap: ``pop`` always returns the smallest element
  ## according to ``<`` on ``T``. ``push`` never blocks; ``pop`` waits when
  ## the heap is empty.
  heap: HeapQueue[T]
  getters: seq[Future[void].Raising([CancelledError])]

proc newAsyncHeapQueue*[T](): AsyncHeapQueue[T] =
  AsyncHeapQueue[T](heap: initHeapQueue[T]())

proc len*[T](aq: AsyncHeapQueue[T]): int {.inline.} =
  aq.heap.len

proc empty*[T](aq: AsyncHeapQueue[T]): bool {.inline.} =
  aq.heap.len == 0

proc wakeupNext[T](getters: var seq[T]) =
  # Wake the first non-finished waiter; drop any finished ones we walked past.
  var i = 0
  while i < getters.len:
    let waiter = getters[i]
    inc i
    if not waiter.finished:
      waiter.complete()
      break
  for _ in 0 ..< i:
    getters.delete(0)

proc push*[T](aq: AsyncHeapQueue[T], item: sink T) =
  ## Insert ``item`` into the heap and wake one waiting popper, if any.
  aq.heap.push(item)
  aq.getters.wakeupNext()

proc pop*[T](aq: AsyncHeapQueue[T]): Future[T] {.async: (raises: [CancelledError]).} =
  ## Remove and return the smallest item. Suspends while the heap is empty.
  while aq.empty:
    let getter = Future[void].Raising([CancelledError]).init("AsyncHeapQueue.pop")
    aq.getters.add(getter)
    try:
      await getter
    except CancelledError as exc:
      if not aq.empty and not getter.cancelled:
        # Pass our wake-up to the next waiter so they don't starve.
        aq.getters.wakeupNext()
      raise exc
  aq.heap.pop()
