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

export sets, tables, messages, options

type
  CacheEntry* = object
    mid*: MessageID
    topicIDs*: seq[string]

  MCache* = object of RootObj
    msgs*: Table[MessageID, Message]
    history*: seq[seq[CacheEntry]]
    historySize*: Natural
    windowSize*: Natural

func get*(c: MCache, mid: MessageID): Option[Message] =
  result = none(Message)
  if mid in c.msgs:
    result = some(c.msgs[mid])

func contains*(c: MCache, mid: MessageID): bool =
  c.get(mid).isSome

func put*(c: var MCache, msgId: MessageID, msg: Message) =
  if msgId notin c.msgs:
    c.msgs[msgId] = msg
    c.history[0].add(CacheEntry(mid: msgId, topicIDs: msg.topicIDs))

func window*(c: MCache, topic: string): HashSet[MessageID] =
  result = initHashSet[MessageID]()

  let
    len = min(c.windowSize, c.history.len)

  for i in 0..<len:
    for entry in c.history[i]:
      for t in entry.topicIDs:
        if t == topic:
          result.incl(entry.mid)
          break

func shift*(c: var MCache) =
  for entry in c.history.pop():
    c.msgs.del(entry.mid)

  c.history.insert(@[])

func init*(T: type MCache, window, history: Natural): T =
  T(
    history: newSeq[seq[CacheEntry]](history),
    historySize: history,
    windowSize: window
  )
