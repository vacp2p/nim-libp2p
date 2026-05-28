# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/heapqueue
import chronos

type AsyncHeapQueue*[T] = ref object
  ## Unbounded async min-heap: ``pop`` always returns the smallest element
  ## according to ``<`` on ``T``. ``push`` never blocks; ``pop`` waits when
  ## the heap is empty.
  ##
  ## The data lives in ``heap``; ``signal`` is an unbounded ``AsyncQueue``
  ## used purely as a wake-up channel — one token per pushed item — so we
  ## inherit chronos's multi-waiter + cancellation handling for free. The
  ## payload type is arbitrary (``AsyncQueue[void]`` won't compile because
  ## chronos backs it with a ``Deque``).
  heap: HeapQueue[T]
  signal: AsyncQueue[byte]

proc newAsyncHeapQueue*[T](): AsyncHeapQueue[T] =
  AsyncHeapQueue[T](heap: initHeapQueue[T](), signal: newAsyncQueue[byte]())

proc len*[T](aq: AsyncHeapQueue[T]): int =
  aq.heap.len

proc empty*[T](aq: AsyncHeapQueue[T]): bool =
  aq.heap.len == 0

proc push*[T](aq: AsyncHeapQueue[T], item: sink T) =
  ## Insert ``item`` into the heap and wake one waiting popper, if any.
  # Push to the heap before signaling so a woken waiter always finds the item.
  aq.heap.push(item)
  # ``putNoWait`` is typed to raise ``AsyncQueueFullError``, but ``signal`` is
  # unbounded (default ``maxsize = 0``), so the branch is unreachable.
  try:
    aq.signal.putNoWait(0)
  except AsyncQueueFullError as exc:
    raiseAssert "unbounded AsyncQueue full: " & exc.msg

proc pop*[T](aq: AsyncHeapQueue[T]): Future[T] {.async: (raises: [CancelledError]).} =
  ## Remove and return the smallest item. Suspends while the heap is empty.
  discard await aq.signal.get()
  aq.heap.pop()
