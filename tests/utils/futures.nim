import chronos/futures, stew/results, chronos, sequtils
import ../pubsub/utils
const
  TEST_GOSSIPSUB_HEARTBEAT_INTERVAL* = 50.milliseconds
  DURATION_TIMEOUT* =
    int64(float64(TEST_GOSSIPSUB_HEARTBEAT_INTERVAL.milliseconds) * 1.2).milliseconds
  DURATION_TIMEOUT_EXTENDED* = TEST_GOSSIPSUB_HEARTBEAT_INTERVAL * 2

type FutureStateWrapper*[T] = object
  future: Future[T]
  state: FutureState
  when T is void:
    discard
  else:
    value: T

proc isPending*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Pending

proc isCompleted*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Completed

proc isCompleted*[T](wrapper: FutureStateWrapper[T], expectedValue: T): bool =
  when T is void:
    wrapper.state == Completed
  else:
    wrapper.state == Completed and wrapper.value == expectedValue

proc isCancelled*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Cancelled

proc isFailed*(wrapper: FutureStateWrapper): bool =
  wrapper.state == Failed

proc toState*[T](future: Future[T]): FutureStateWrapper[T] =
  var wrapper: FutureStateWrapper[T]
  wrapper.future = future

  if future.cancelled():
    wrapper.state = Cancelled
  elif future.finished():
    if future.failed():
      wrapper.state = Failed
    else:
      wrapper.state = Completed
      when T isnot void:
        wrapper.value = future.read()
  else:
    wrapper.state = Pending

  return wrapper

proc waitForState*[T](
    future: Future[T], timeout = DURATION_TIMEOUT
): Future[FutureStateWrapper[T]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toState()

proc waitForStates*[T](
    futures: seq[Future[T]], timeout = DURATION_TIMEOUT
): Future[seq[FutureStateWrapper[T]]] {.async.} =
  await sleepAsync(timeout)
  return futures.mapIt(it.toState())
