import ./consts
import ./protobuf
import ./xordistance
import ./keys
import ../../[peerid, peerinfo]
import algorithm
import chronicles

type
  LookupNode* = object
    peerId: PeerId
    distance: XorDistance
    queried: bool # have we already queried this node?
    pending: bool # is there an active request rn?
    failed: bool # did the query timeout or error?

  LookupState* = object
    targetId: Key
    shortlist: seq[LookupNode] # current known closest node
    activeQueries*: int # how many queries in flight
    alpha: int # parallelism level
    repliCount: int ## aka `k` in the spec: number of closest nodes to find
    done*: bool # has lookup converged

proc alreadyInShortlist(state: LookupState, peer: Peer): bool =
  for p in state.shortlist:
    if p.peerId.getBytes() == peer.id:
      return true
  return false

proc updateShortlist*(
    state: var LookupState, msg: Message, onInsert: proc(p: PeerInfo) {.gcsafe.}
) =
  for newPeer in msg.closerPeers:
    if not alreadyInShortlist(state, newPeer):
      let peerInfo =
        PeerInfo(peerId: PeerId.init(newPeer.id).get(), addrs: newPeer.addrs)
      try:
        onInsert(peerInfo)
        state.shortlist.add(
          LookupNode(
            peerId: peerInfo.peerId,
            distance: xorDistance(peerInfo.peerId, state.targetId),
            queried: false,
            pending: false,
            failed: false,
          )
        )
      except Exception as exc:
        debug "could not update shortlist", err = exc.msg

  state.shortlist.sort(
    proc(a, b: LookupNode): int =
      cmp(a.distance, b.distance)
  )

  state.activeQueries.dec

proc markFailed*(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.failed = true
      p.pending = false
      p.queried = true
      state.activeQueries.dec
      break

proc markPending*(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.pending = true
      p.queried = true
      break

proc selectAlphaPeers*(state: LookupState): seq[PeerId] =
  var selected: seq[PeerId] = @[]
  for p in state.shortlist:
    if not p.queried and not p.failed and not p.pending:
      selected.add(p.peerId)
      if selected.len >= state.alpha:
        break
  return selected

proc init*(T: type LookupState, targetId: Key, initialPeers: seq[PeerId]): T =
  result = LookupState(
    targetId: targetId,
    shortlist: @[],
    activeQueries: 0,
    alpha: alpha,
    repliCount: DefaultReplic,
    done: false,
  )
  for p in initialPeers:
    result.shortlist.add(
      LookupNode(
        peerId: p,
        distance: xorDistance(p, targetId),
        queried: false,
        pending: false,
        failed: false,
      )
    )

  result.shortlist.sort(
    proc(a, b: LookupNode): int =
      cmp(a.distance, b.distance)
  )

proc checkConvergence*(state: LookupState): bool =
  let ready = state.activeQueries == 0
  let noNew = selectAlphaPeers(state).len == 0
  return ready and noNew

proc selectClosestK*(state: LookupState): seq[PeerId] =
  result = @[]
  for p in state.shortlist:
    if not p.failed:
      result.add(p.peerId)
      if result.len >= state.repliCount:
        break
