import random
import chronos
import ../libp2p/utils/semaphore

import ./helpers

randomize()

suite "AsyncSemaphore":
  asyncTest "should acquire":
    let sema = AsyncSemaphore.init(3)

    await sema.acquire()
    await sema.acquire()
    await sema.acquire()

    check sema.count == 0

  asyncTest "should release":
    let sema = AsyncSemaphore.init(3)

    await sema.acquire()
    await sema.acquire()
    await sema.acquire()

    check sema.count == 0
    sema.release()
    sema.release()
    sema.release()
    check sema.count == 3

  asyncTest "should queue acquire":
    let sema = AsyncSemaphore.init(1)

    await sema.acquire()
    let fut = sema.acquire()

    check sema.count == -1
    check sema.queue.len == 1
    sema.release()
    sema.release()
    check sema.count == 1

    await sleepAsync(10.millis)
    check fut.finished()

  asyncTest "should keep count == size":
    let sema = AsyncSemaphore.init(1)
    sema.release()
    sema.release()
    sema.release()
    check sema.count == 1

  asyncTest "should tryAcquire":
    let sema = AsyncSemaphore.init(1)
    await sema.acquire()
    check sema.tryAcquire() == false

  asyncTest "should tryAcquire and acquire":
    let sema = AsyncSemaphore.init(4)
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.count == 0

    let fut = sema.acquire()
    check fut.finished == false
    check sema.count == -1
    # queue is only used when count is < 0
    check sema.queue.len == 1

    sema.release()
    sema.release()
    sema.release()
    sema.release()
    sema.release()

    check fut.finished == true
    check sema.count == 4
    check sema.queue.len == 0

  asyncTest "should restrict resource access":
    let sema = AsyncSemaphore.init(3)
    var resource = 0

    proc task() {.async.} =
      try:
        await sema.acquire()
        resource.inc()
        check resource > 0 and resource <= 3
        let sleep = rand(0..10).millis
        # echo sleep
        await sleepAsync(sleep)
      finally:
        resource.dec()
        sema.release()

    var tasks: seq[Future[void]]
    for i in 0..<10:
      tasks.add(task())

    await allFutures(tasks)
