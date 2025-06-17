import std/[tables, heapqueue, options]
import ./types
import chronos
import ../rpc/messages

proc `<`(a, b: PreambleInfo): bool =
  a.expiresAt < b.expiresAt

proc initPreambleStore*(): PreambleStore =
  result.byId = initTable[MessageId, PreambleInfo]()
  result.heap = initHeapQueue[PreambleInfo]()

proc insert*(ps: var PreambleStore, msgId: MessageId, info: PreambleInfo) =
  try:
    if ps.byId.hasKey(msgId):
      ps.byId[msgId].deleted = true
    ps.byId[msgId] = info
    ps.heap.push(info)
  except KeyError:
    assert false, "checked with hasKey"

proc hasKey*(ps: var PreambleStore, msgId: MessageId): bool =
  return ps.byId.hasKey(msgId)

proc `[]`*(ps: var PreambleStore, msgId: MessageId): PreambleInfo =
  ps.byId[msgId]

proc `[]=`*(ps: var PreambleStore, msgId: MessageId, entry: PreambleInfo) =
  insert(ps, msgId, entry)

proc del*(ps: var PreambleStore, msgId: MessageId): bool =
  try:
    if ps.byId.hasKey(msgId):
      ps.byId[msgId].deleted = true
      ps.byId.del(msgId)
      return true
    return false
  except KeyError:
    assert false, "checked with hasKey"

proc len*(ps: var PreambleStore): int =
  return ps.byId.len

proc popExpired*(ps: var PreambleStore, now: Moment): Option[PreambleInfo] =
  while ps.heap.len > 0:
    if not ps.heap[0].deleted:
      discard ps.heap.pop()
    elif ps.heap[0].expiresAt <= now:
      let top = ps.heap.pop()
      ps.byId.del(top.messageId)
      return some(top)
    else:
      return none(PreambleInfo)

template withValue*(ps: var PreambleStore, key: MessageId, value, body: untyped) =
  try:
    if ps.hasKey(key):
      let value {.inject.} = ps.byId[key]
      body
  except KeyError:
    assert false, "checked with in"
