import std/[tables, heapqueue, sets, options]
import ./types
import chronos
import ../rpc/messages
import ../../../peerid
import ../pubsubpeer

proc `<`(a, b: PreambleInfo): bool =
  a.expiresAt < b.expiresAt

proc init*(T: typedesc[PeerSet]): T =
  PeerSet(order: @[], peers: initHashSet[PeerId]())

proc init*(
    T: typedesc[PreambleInfo],
    preamble: ControlPreamble,
    sender: PubSubPeer,
    startsAt: Moment,
    expiresAt: Moment,
): T =
  PreambleInfo(
    messageId: preamble.messageID,
    messageLength: preamble.messageLength,
    topicId: preamble.topicID,
    sender: sender,
    startsAt: startsAt,
    expiresAt: expiresAt,
    peerSet: PeerSet.init(),
  )

proc init*(T: typedesc[PreambleStore]): T =
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

proc del*(ps: var PreambleStore, msgId: MessageId) =
  try:
    if ps.byId.hasKey(msgId):
      ps.byId[msgId].deleted = true
      ps.byId.del(msgId)
  except KeyError:
    assert false, "checked with hasKey"

proc len*(ps: var PreambleStore): int =
  return ps.byId.len

proc popExpired*(ps: var PreambleStore, now: Moment): Option[PreambleInfo] =
  while ps.heap.len > 0:
    if ps.heap[0].deleted:
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
  except system.KeyError:
    assert false, "checked with in"

const maxPossiblePeersOnPeerSet = 6

proc addPossiblePeerToQuery*(
    ps: var PreambleStore, msgId: MessageId, peer: PubSubPeer
) =
  if not ps.hasKey(msgId):
    return

  try:
    var preamble = ps[msgId]
    if not preamble.peerSet.peers.contains(peer.peerId):
      if preamble.peerSet.order.len == maxPossiblePeersOnPeerSet:
        let evicted: PeerId = preamble.peerSet.order[0]
        preamble.peerSet.order.delete(0)
        preamble.peerSet.peers.excl(evicted)
      preamble.peerSet.order.add(peer.peerId)
      preamble.peerSet.peers.incl(peer.peerId)
  except KeyError:
    assert false, "checked with hasKey"

proc possiblePeersToQuery*(preamble: PreambleInfo): seq[PeerId] =
  preamble.peerSet.order
