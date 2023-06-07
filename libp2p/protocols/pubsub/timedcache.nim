# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[tables]

import chronos/timer, stew/results

const Timeout* = 10.seconds # default timeout in ms

type
  TimedEntry*[K] = ref object of RootObj
    key: K
    addedAt: Moment
    expiresAt: Moment
    next, prev: TimedEntry[K]

  TimedCache*[K] = object of RootObj
    head, tail: TimedEntry[K] # nim linked list doesn't allow inserting at pos
    entries: Table[K, TimedEntry[K]]
    timeout: Duration

func expire*(t: var TimedCache, now: Moment = Moment.now()) =
  while t.head != nil and t.head.expiresAt < now:
    t.entries.del(t.head.key)
    t.head.prev = nil
    t.head = t.head.next
    if t.head == nil: t.tail = nil

func del*[K](t: var TimedCache[K], key: K): Opt[TimedEntry[K]] =
  # Removes existing key from cache, returning the previous value if present
  var item: TimedEntry[K]
  if t.entries.pop(key, item):
    if t.head == item: t.head = item.next
    if t.tail == item: t.tail = item.prev

    if item.next != nil: item.next.prev = item.prev
    if item.prev != nil: item.prev.next = item.next
    Opt.some(item)
  else:
    Opt.none(TimedEntry[K])

func put*[K](t: var TimedCache[K], k: K, now = Moment.now()): bool =
  # Puts k in cache, returning true if the item was already present and false
  # otherwise. If the item was already present, its expiry timer will be
  # refreshed.
  t.expire(now)

  var previous = t.del(k) # Refresh existing item

  let addedAt =
    if previous.isSome: previous.get().addedAt
    else: now

  let node = TimedEntry[K](key: k, addedAt: addedAt, expiresAt: now + t.timeout)

  if t.head == nil:
    t.tail = node
    t.head = t.tail
  else:
    # search from tail because typically that's where we add when now grows
    var cur = t.tail
    while cur != nil and node.expiresAt < cur.expiresAt:
      cur = cur.prev

    if cur == nil:
      node.next = t.head
      t.head.prev = node
      t.head = node
    else:
      node.prev = cur
      node.next = cur.next
      cur.next = node
      if cur == t.tail:
        t.tail = node

  t.entries[k] = node

  previous.isSome()

func contains*[K](t: TimedCache[K], k: K): bool =
  k in t.entries

func addedAt*[K](t: TimedCache[K], k: K): Moment =
  t.entries.getOrDefault(k).addedAt


func init*[K](T: type TimedCache[K], timeout: Duration = Timeout): T =
  T(
    timeout: timeout
  )
