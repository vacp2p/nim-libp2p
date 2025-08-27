# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

# import options
import chronicles
import chronos
import sequtils
import ../routing_record
import ../peerstore
import ../dial
import ../stream/lpstream
import
  ./discoverymngr,
  ../protocols/kademlia,
  ../protocols/kademlia/[kademlia, keys, routingtable, lookupstate, consts, protobuf],
  ../[peerid, peerinfo]

# TODO: set up this const properly
const DiscLimit = 420
type
  KadDiscovery* = ref object of DiscoveryInterface
    kad*: KadDHT
    timeToRequest: Duration
    timeToAdvertise: Duration
    ttl: Duration

  Register = object
    namespace: string
    signedPeerRecord: seq[byte]
    ttl: Opt[uint64] # in seconds

  Discover = object
    namespace: Opt[string]
    limit: Opt[uint64]

  KadNamespace* = distinct string

proc `==`*(a, b: KadNamespace): bool {.borrow.}

proc discoverNode*(
    self: KadDiscovery, targetId: Key, namespace: Opt[string]
): Future[seq[PeerId]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  #debug "findNode", target = target
  # TODO: should it return a single peer instead? read spec

  var initialPeers = self.kad.rtable.findClosestPeers(targetId, DefaultReplic)
  var state = LookupState.init(targetId, initialPeers)
  var addrTable: Table[PeerId, seq[MultiAddress]] =
    initTable[PeerId, seq[MultiAddress]]()

  while not state.done:
    let toQuery = state.selectAlphaPeers()

    var pendingFutures = initTable[PeerId, Future[Message]]()

    for qPeer in toQuery:
      if pendingFutures.hasKey(qPeer):
        continue

      state.markPending(qPeer)

      pendingFutures[qPeer] = self.kad
        .sendFindNode(qPeer, addrTable.getOrDefault(qPeer, @[]), targetId)
        .wait(5.seconds)

      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      for closerPeer in msg.closerPeers:
        addrTable[PeerId.init(closerPeer.id).get()] = closerPeer.addrs
        var attr: PeerAttributes
        for address in closerPeer.addrs:
          attr.add(address)
        attr.add(DiscoveryService(namespace.get()))
        attr.add(KadNamespace(namespace.get()))
        self.onPeerFound(attr)
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) =
          discard self.kad.rtable.insert(p.peerId)
          self.kad.switch.peerStore[AddressBook][p.peerId] = p.addrs
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
          # TODO: for discovery interface, invoke the found-peer handler
          # TODO: when peer-find limit is reached, interupt the hunt.
        ,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    state.done = state.checkConvergence()

  return state.selectClosestK()

method request*(
    self: KadDiscovery, pa: PeerAttributes
) {.base, async: (raises: [DiscoveryError, CancelledError, LPError]).} =
  # for attr in pa:
  #   if attr.ofType(KadNamespace):
  #     namespace = Opt.some(string attr.to(KadNamespace))
  #   elif attr.ofType(DiscoveryService):
  #     namespace = Opt.some(string attr.to(DiscoveryService))
  #   elif attr.ofType(PeerId):
  #     namespace = Opt.some($attr.to(PeerId))
  #   else:
  #     # unhandled type
  #     return
  var namespace = Opt.some("hardcodedForNow")
  while true:
    # TODO: instead of request, do something like `findNode`, with the additional actions in addition to Routing table insertion
    #  - pass up the attributes to discovery manager
    #  - check if discovery limit is reached.
    let id = PeerId.random(self.kad.rng).tryGet().toKey()
    discard await self.discoverNode(id, namespace)

    await sleepAsync(self.timeToRequest)

proc requestPeer(
    peer: PeerId
) {.async: (raises: [LPStreamError, DialFailedError, CancelledError]).} =
  discard

proc doRequest(
    kad: KadDHT, namespace: Opt[string], limit: uint32, peers: seq[PeerId]
): Future[seq[PeerRecord]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  var
    s: Table[PeerId, (PeerRecord, Register)]
    limit: uint64
    namespace = Opt.some("hardcoded")
    disc = Discover(namespace: namespace)

  # TODO: set the limit type to be a `Range[1, X]` type
  if limit <= 0 or limit > DiscLimit:
    raise newException(AdvertiseError, "Invalid limit")
  # if namespace.isSome() and namespace.get().len > MaximumNamespaceLen:
  #   raise newException(AdvertiseError, "Invalid namespace")

  for peer in peers:
    if KadCodec notin kad.switch.peerStore[ProtoBook][peer]:
      continue
    try:
      trace "Send Request", peerId = peer, namespace
      await peer.requestPeer()
    except CancelledError as e:
      raise e
    except DialFailedError as e:
      trace "failed to dial a peer", description = e.msg
    except LPStreamError as e:
      trace "failed to communicate with a peer", description = e.msg
  return toSeq(s.values()).mapIt(it[0])
  discard

method advertise*(
    self: KadDiscovery
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  warn "advertise not yet implemented: blocked pending put/get impl"
  discard
  # while true:
  #   var toAdvertise: seq[string]
  #   for attr in self.toAdvertise:
  #     if attr.ofType(KadNamespace):
  #       toAdvertise.add string attr.to(KadNamespace)
  #     elif attr.ofType(DiscoveryService):
  #       toAdvertise.add string attr.to(DiscoveryService)
  #     elif attr.ofType(PeerId):
  #       toAdvertise.add $attr.to(PeerId)
  #
  #   self.advertisementUpdated.clear()
  #   for toAdv in toAdvertise:
  #     try:
  #       await self.kad.advertise(toAdv, self.ttl)
  #     except CatchableError as error:
  #       debug "Kad advertise error: ", description = error.msg
  #
  #   await sleepAsync(self.timeToAdvertise) or self.advertisementUpdated.wait()

proc new*(
    T: typedesc[KadDiscovery],
    kad: KadDHT,
    ttr: Duration = 1.minutes,
    tta: Duration = 1.minutes,
    ttl: Duration = ttl,
): KadDiscovery =
  T(kad: kad, timeToRequest: ttr, timeToAdvertise: tta, ttl: ttl)
