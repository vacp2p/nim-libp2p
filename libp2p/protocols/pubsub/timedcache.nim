## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[heapqueue, sets]

import chronos/timer

const Timeout* = 10.seconds # default timeout in ms

type
  TimedEntry*[K] = ref object of RootObj
    key: K
    expiresAt: Moment

  TimedCache*[K] = object of RootObj
    expiries: HeapQueue[TimedEntry[K]]
    entries: HashSet[K]
    timeout: Duration

func `<`*(a, b: TimedEntry): bool =
  a.expiresAt < b.expiresAt

func expire*(t: var TimedCache, now: Moment = Moment.now()) =
  while t.expiries.len() > 0 and t.expiries[0].expiresAt < now:
    t.entries.excl(t.expiries.pop().key)

func del*[K](t: var TimedCache[K], key: K): bool =
  # Removes existing key from cache, returning false if it was not present
  if not t.entries.missingOrExcl(key):
    for i in 0..<t.expiries.len:
      if t.expiries[i].key == key:
        t.expiries.del(i)
        break
    true
  else:
    false

func put*[K](t: var TimedCache[K], k: K, now = Moment.now()): bool =
  # Puts k in cache, returning true if the item was already present and false
  # otherwise. If the item was already present, its expiry timer will be
  # refreshed.
  t.expire(now)

  var res = t.del(k) # Refresh existing item

  t.entries.incl(k)
  t.expiries.push(TimedEntry[K](key: k, expiresAt: now + t.timeout))

  res

func contains*[K](t: TimedCache[K], k: K): bool =
  k in t.entries

func init*[K](T: type TimedCache[K], timeout: Duration = Timeout): T =
  T(
    expiries: initHeapQueue[TimedEntry[K]](),
    entries: initHashSet[K](),
    timeout: timeout
  )
