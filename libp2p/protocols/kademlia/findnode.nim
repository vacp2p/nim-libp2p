const
  IdLength = 32 # 256-bit IDs
  k = 20        # bucket size
  alpha = 3     # parallelism factor
  ttl = 24.hours

type
  XorDistance* = array[IdLength, byte]


type
  LookupPeer = object
    peerId: PeerId
    distance: XorDistance 
    queried: bool # have we already queried this peer?
    pending: bool # is there an active request rn?
    failed: bool # did the query timeout or error?

  LookupState = object
    targetId: PeerId
    shortlist: seq[LookupPeer] # current known closest peers
    activeQueries: int # how many queries in flight
    alpha: int # parallelism level
    k: int # number of closest nodes to find
    done: bool # has lookup converged


proc alreadyInShortlist(state: LookupState, peer: Peer): bool =
  for p in state.shortlist:
    if p.peerId == peer.id:
      return true
  return false


proc updateShortlist(state: var LookupState, reply: Reply) =
  for newPeer in reply.peers:
    if not alreadyInShortlist(state, newPeer):
      state.shortlist.add(LookupPeer(
        peerId: newPeer.id,
        distance: xorDistance(newPeer.id, state.targetId),
        queried: false,
        pending: false,
        failed: false
      ))

  state.shortlist.sort((a, b) => a.distance < b.distance)
  state.activeQueries.dec

proc markFailed(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.failed = true
      p.pending = false
      p.queried = true
      state.activeQueries.dec
      break

proc markPending(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.pending = true
      p.queried = true
      break

proc selectAlphaPeers(state: LookupState): seq[PeerId] =
  var selected: seq[PeerId] = @[]

  for p in state.shortlist:
    if not p.queried and not p.failed and not p.pending:
      selected.add(p.peerId)
      if selected.len >= state.alpha:
        break

  return selected

proc initLookupState(targetId: PeerId): LookupState =
  var peers = getInitialClosestPeers(targetId) # TODO: implement routing table
  result = LookupState(
    targetId: targetId,
    shortlist: @[],
    activeQueries: 0,
    alpha: alpha,
    k: k,
    done: false
  )
  for peer in peers:
    result.shortlist.add(LookupPeer(
      peerId: peer,
      distance: xorDistance(peer, targetId),
      queried: false,
      pending: false,
      failed: false
    ))
  result.shortlist.sort((a, b) => a.distance < b.distance)

proc checkConvergence(state: LookupState): bool =
  let ready = state.activeQueries == 0
  let noNew = selectAlphaPeers(state).len == 0
  return ready and noNew

proc selectClosestK(state: LookupState): seq[PeerId] =
  result = @[]
  for p in state.shortlist:
    if not p.failed:
      result.add(p.peerId)
      if result.len >= state.k:
        break

proc sendFindNode(peerId: PeerId, targetId: PeerId): Future[void] {.async.} =
  let connection = await switch.dial(peerId, peer.Addr, "/ipfs/kad/1.0.0") # TODO: const
  await connection.write(encodeFindNodeRequest(targetId)) # TODO: encodeFindNodeRequest
  return connection

proc findNode(target: PeerId): Future[seq[PeerId]] =
  var state = initLookupState(target)



  while not state.done:
    let toQuery = selectAlphaPeers(state)

    var pendingFutures: Table[PeerId, Future[Reply]] = initTable()

    for peer in toQuery:
      if pendingFutures.hasKey(peer):
        continue

      markPending(state, peer)
      pendingFutures[peer] = sendFindNode(peer, target)
      state.activeQueries.inc

    successful, timedOut = await waitRepliesOrTimeouts(pendingFutures) # TODO

    for reply in successful: # TODO:
      updateShortlist(state, reply)

    for timedOut in timedOutPeers():
      markFailed(state, timedOut)

    state.done = checkConvergence(state)

  return selectClosestK(state)
