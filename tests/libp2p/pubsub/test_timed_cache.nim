# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/hashes
import chronos/timer
import ../../../libp2p/protocols/pubsub/timedcache
import ../../tools/unittest

type TrackedKey = ref object
  id: int

var finalizedTrackedKeys: int

proc finalizeTrackedKey(key: TrackedKey) =
  inc finalizedTrackedKeys

proc `==`(a, b: TrackedKey): bool =
  a.id == b.id

proc hash(key: TrackedKey): Hash =
  hash(key.id)

proc putTracked(cache: var TimedCache[TrackedKey], id: int, now: Moment) =
  var key: TrackedKey
  new(key, finalizeTrackedKey)
  key.id = id
  discard cache.put(key, now)

suite "TimedCache":
  test "expired entries are released while the cache remains populated":
    finalizedTrackedKeys = 0
    var cache = TimedCache[TrackedKey].init(5.seconds)
    let now = Moment.now()

    cache.putTracked(0, now)
    cache.putTracked(1, now + 1.seconds)

    cache.expire(now + 5.seconds + 1.nanoseconds)
    GC_fullCollect()
    check:
      cache.len == 1
      finalizedTrackedKeys == 1

    cache.expire(now + 6.seconds + 1.nanoseconds)
    GC_fullCollect()
    check finalizedTrackedKeys == 2

  test "middle insertion preserves expiration order":
    var cache = TimedCache[int].init(5.seconds)
    let now = Moment.now()

    check:
      not cache.put(1, now)
      not cache.put(3, now + 2.seconds)
      not cache.put(2, now + 1.seconds)
      not cache.put(4, now + 1500.milliseconds)

    cache.expire(now + 6.seconds + 1.nanoseconds)
    check:
      1 notin cache
      2 notin cache
      3 in cache
      4 in cache

  test "deleted entry does not retain its former neighbors":
    finalizedTrackedKeys = 0
    var cache = TimedCache[TrackedKey].init(5.seconds)
    let now = Moment.now()

    for id in 0 ..< 3:
      cache.putTracked(id, now)

    let removed = cache.del(TrackedKey(id: 1))
    check:
      removed.isSome()
      cache.len == 2

    cache.expire(now + 5.seconds + 1.nanoseconds)
    GC_fullCollect()
    check:
      cache.len == 0
      finalizedTrackedKeys == 2

  test "put/get":
    var cache = TimedCache[int].init(5.seconds)

    let now = Moment.now()
    check:
      not cache.put(1, now)
      not cache.put(2, now + 3.seconds)

    check:
      1 in cache
      2 in cache

    check:
      not cache.put(3, now + 6.seconds)
      # expires 1

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
    for i in 101 .. 100000:
      check:
        not cache.put(i, now)

    for i in 101 .. 100000:
      check:
        i in cache

  test "max size constraint":
    var cache = TimedCache[int].init(5.seconds, 3) # maxSize = 3

    let now = Moment.now()
    check:
      not cache.put(1, now)
      not cache.put(2, now + 1.seconds)
      not cache.put(3, now + 2.seconds)

    check:
      1 in cache
      2 in cache
      3 in cache

    check:
      not cache.put(4, now + 3.seconds) # exceeds maxSize, evicts 1

    check:
      1 notin cache
      2 in cache
      3 in cache
      4 in cache

    check:
      not cache.put(5, now + 4.seconds) # exceeds maxSize, evicts 2

    check:
      1 notin cache
      2 notin cache
      3 in cache
      4 in cache
      5 in cache

    check:
      not cache.put(6, now + 5.seconds) # exceeds maxSize, evicts 3

    check:
      1 notin cache
      2 notin cache
      3 notin cache
      4 in cache
      5 in cache
      6 in cache

  test "max size with expiration":
    var cache = TimedCache[int].init(3.seconds, 2) # maxSize = 2

    let now = Moment.now()
    check:
      not cache.put(1, now)
      not cache.put(2, now + 1.seconds)

    check:
      1 in cache
      2 in cache

    check:
      not cache.put(3, now + 5.seconds) # expires 1 and 2, should only contain 3

    check:
      1 notin cache
      2 notin cache
      3 in cache

  test "max size constraint with refresh":
    var cache = TimedCache[int].init(5.seconds, 3) # maxSize = 3

    let now = Moment.now()
    check:
      not cache.put(1, now)
      not cache.put(2, now + 1.seconds)
      not cache.put(3, now + 2.seconds)

    check:
      1 in cache
      2 in cache
      3 in cache

    check:
      cache.put(1, now + 3.seconds) # refreshes 1, now 2 is the oldest

    check:
      not cache.put(4, now + 3.seconds) # exceeds maxSize, evicts 2

    check:
      1 in cache
      2 notin cache
      3 in cache
      4 in cache
