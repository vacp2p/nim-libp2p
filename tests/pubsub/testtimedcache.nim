{.used.}

import unittest2
import chronos/timer
import ../../libp2p/protocols/pubsub/timedcache

suite "TimedCache":
  test "put/get":
    var cache = TimedCache[int].init(5.seconds)

    let now = Moment.now()
    check:
      not cache.put(1, now)
      not cache.put(2, now + 3.seconds)

    check:
      1 in cache
      2 in cache

    check: not cache.put(3, now + 6.seconds) # expires 1

    check:
      1 notin cache
      2 in cache
      3 in cache

      cache.addedAt(2) == now + 3.seconds

    check:
      cache.put(2, now + 7.seconds) # refreshes 2
      not cache.put(4, now + 12.seconds) # expires 3

    check:
      2 in cache
      3 notin cache
      4 in cache

    check:
      cache.del(4).isSome()
      4 notin cache

    check:
      not cache.put(100, now + 100.seconds) # expires everything
      100 in cache
      2 notin cache

  test "enough items to force cache heap storage growth":
    var cache = TimedCache[int].init(5.seconds)

    let now = Moment.now()
    for i in 101..100000:
      check:
        not cache.put(i, now)

    for i in 101..100000:
      check:
        i in cache
