## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sets, tables, options]
import rpc/[messages]

export tables, messages, options

type
  CacheEntry* = object
    mid*: string
    topicIDs*: seq[string]

  MCache* = object of RootObj
    msgs*: Table[string, Message]
    history*: seq[seq[CacheEntry]]
    historySize*: Natural
    windowSize*: Natural

proc get*(c: MCache, mid: string): Option[Message] =
  result = none(Message)
  if mid in c.msgs:
    result = some(c.msgs[mid])

proc contains*(c: MCache, mid: string): bool =
  c.get(mid).isSome

proc put*(c: var MCache, msgId: string, msg: Message) =
  if msgId notin c.msgs:
    c.msgs[msgId] = msg
    c.history[0].add(CacheEntry(mid: msgId, topicIDs: msg.topicIDs))

proc window*(c: MCache, topic: string): HashSet[string] =
  result = initHashSet[string]()

  let
    len = min(c.windowSize, c.history.len)

  for i in 0..<len:
    for entry in c.history[i]:
      for t in entry.topicIDs:
        if t == topic:
          result.incl(entry.mid)
          break

proc shift*(c: var MCache) =
  while c.history.len > c.historySize:
    for entry in c.history.pop():
      c.msgs.del(entry.mid)

  c.history.insert(@[])

proc init*(T: type MCache, window, history: Natural): T =
  var res = T(
    history: newSeqOfCap[seq[CacheEntry]](history),
    historySize: history,
    windowSize: window
  )

  res.history.add(newSeq[CacheEntry]())

  res
