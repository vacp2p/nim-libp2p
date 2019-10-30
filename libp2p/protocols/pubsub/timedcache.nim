## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables
import chronos, chronicles

logScope:
  topic = "TimedCache"

# TODO: this should use `Duration`, but the corresponding 
# `addTimer` is missing from chronos
const Timeout* = 10 * 1000 # default timeout in ms

type
  ExpireHandler*[V] = proc(key: string, val: V) {.gcsafe.}
  TimedEntry*[V] = object of RootObj
    val: V
    handler: ExpireHandler[V]

  TimedCache*[V] = ref object of RootObj
    cache*: Table[string, TimedEntry[V]]
    onExpire*: ExpireHandler[V]

proc newTimedCache*[V](): TimedCache[V] =
  new result
  result.cache = initTable[string, TimedEntry[V]]()

proc put*[V](t: TimedCache[V],
             key: string,
             val: V = "",
             timeout: uint64 = Timeout,
             handler: ExpireHandler[V] = nil) = 
  trace "adding entry to timed cache", key = key, val = val
  t.cache[key] = TimedEntry[V](val: val, handler: handler)

  # TODO: addTimer with param Duration is missing from chronos, needs to be added
  addTimer(
    timeout,
    proc (arg: pointer = nil) {.gcsafe.} =
      trace "deleting expired entry from timed cache", key = key, val = val
      if key in t.cache:
        var entry = t.cache[key]
        t.cache.del(key)
        if not isNil(entry.handler):
          entry.handler(key, entry.val)
  )

proc contains*[V](t: TimedCache[V], key: string): bool = 
  t.cache.contains(key)

proc del*[V](t: TimedCache[V], key: string) =
  trace "deleting entry from timed cache", key = key
  t.cache.del(key)
