## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, options, deques, math
import rpc/[messages, message]

type
  CacheEntry* = object
    mid*: string
    msg*: Message

  MCache* = ref object of RootObj
    msgs*: Table[string, Message]
    history*: Deque[seq[CacheEntry]]
    historySize*: Natural
    window*: Natural

proc put*(c: MCache, msg: Message) = 
  c.msgs[msg.msgId] = msg
  c.history[0].add(CacheEntry(mid: msg.msgId, msg: msg))

proc get*(c: MCache, mid: string): Option[Message] =
  result = none(Message)
  if mid in c.msgs:
    result = some(c.msgs[mid])

proc window*(c: MCache, topic: string): seq[Message] = 
  for i, msgs in c.history:
    if i == c.window:
      break

    for m in msgs:
      for t in m.msg.topicIDs:
        if t == topic:
          result.add(m.msg)
          break

proc shift*(c: MCache) = 
  for entry in c.history.popLast():
    c.msgs.del(entry.mid)

  c.history.addFirst(newSeq[CacheEntry]())

proc newMCache*(window: Natural, history: Natural): MCache =
  new result
  result.historySize = history
  result.window = window
  result.history = initDeque[seq[CacheEntry]](nextPowerOfTwo(history))
  for i in 0..history:
    result.history.addFirst(@[])

  result.msgs = initTable[string, Message]()
