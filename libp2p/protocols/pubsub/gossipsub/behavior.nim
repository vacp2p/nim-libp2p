## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, strutils, sequtils, sets]
import random # for shuffle
import chronos, chronicles, metrics
import "."/[types, scoring]
import ".."/[pubsubpeer, peertable, timedcache, mcache]
import "../rpc"/[messages]
import "../../.."/[peerid, multiaddress, utility, switch]

proc grafted*(g: GossipSub, p: PubSubPeer, topic: string) =
  g.peerStats.withValue(p.peerId, stats):
    var info = stats.topicInfos.getOrDefault(topic)
    info.graftTime = Moment.now()
    info.meshTime = 0.seconds
    info.inMesh = true
    info.meshMessageDeliveriesActive = false

    # mgetOrPut does not work, so we gotta do this without referencing
    stats.topicInfos[topic] = info
    assert(g.peerStats[p.peerId].topicInfos[topic].inMesh == true)

    trace "grafted", peer=p, topic
  do:
    g.initPeerStats(p)
    g.grafted(p, topic)

proc pruned*(g: GossipSub, p: PubSubPeer, topic: string) =
  let backoff = Moment.fromNow(g.parameters.pruneBackoff)
  g.backingOff
    .mgetOrPut(topic, initTable[PeerID, Moment]())
    .mgetOrPut(p.peerId, backoff) = backoff

  g.peerStats.withValue(p.peerId, stats):
    if topic in stats.topicInfos:
      var info = stats.topicInfos[topic]
      if topic in g.topicParams:
        let topicParams = g.topicParams[topic]
        # penalize a peer that delivered no message
        let threshold = topicParams.meshMessageDeliveriesThreshold
        if info.inMesh and info.meshMessageDeliveriesActive and info.meshMessageDeliveries < threshold:
          let deficit = threshold - info.meshMessageDeliveries
          info.meshFailurePenalty += deficit * deficit

      info.inMesh = false

      # mgetOrPut does not work, so we gotta do this without referencing
      stats.topicInfos[topic] = info

      trace "pruned", peer=p, topic

proc handleBackingOff*(t: var BackoffTable, topic: string) =
  let now = Moment.now()
  var expired = toSeq(t.getOrDefault(topic).pairs())
  expired.keepIf do (pair: tuple[peer: PeerID, expire: Moment]) -> bool:
    now >= pair.expire
  for (peer, _) in expired:
    t.mgetOrPut(topic, initTable[PeerID, Moment]()).del(peer)

proc peerExchangeList*(g: GossipSub, topic: string): seq[PeerInfoMsg] =
  var peers = g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()).toSeq()
  peers.keepIf do (x: PubSubPeer) -> bool:
      x.score >= 0.0
  # by spec, larger then Dhi, but let's put some hard caps
  peers.setLen(min(peers.len, g.parameters.dHigh * 2))
  peers.map do (x: PubSubPeer) -> PeerInfoMsg:
    PeerInfoMsg(peerID: x.peerId.getBytes())

proc handleGraft*(g: GossipSub,
                 peer: PubSubPeer,
                 grafts: seq[ControlGraft]): seq[ControlPrune] =
  for graft in grafts:
    let topic = graft.topicID
    logScope:
      peer
      topic

    trace "peer grafted topic"

    # It is an error to GRAFT on a explicit peer
    if peer.peerId in g.parameters.directPeers:
      # receiving a graft from a direct peer should yield a more prominent warning (protocol violation)
      warn "attempt to graft an explicit peer", peer=peer.peerId,
                                                topic
      # and such an attempt should be logged and rejected with a PRUNE
      result.add(ControlPrune(
        topicID: topic,
        peers: @[], # omitting heavy computation here as the remote did something illegal
        backoff: g.parameters.pruneBackoff.seconds.uint64))

      let backoff = Moment.fromNow(g.parameters.pruneBackoff)
      g.backingOff
        .mgetOrPut(topic, initTable[PeerID, Moment]())
        .mgetOrPut(peer.peerId, backoff) = backoff

      peer.behaviourPenalty += 0.1

      continue

    if  g.backingOff
          .getOrDefault(topic)
          .getOrDefault(peer.peerId) > Moment.now():
      warn "attempt to graft a backingOff peer",  peer=peer.peerId,
                                                  topic
      # and such an attempt should be logged and rejected with a PRUNE
      result.add(ControlPrune(
        topicID: topic,
        peers: @[], # omitting heavy computation here as the remote did something illegal
        backoff: g.parameters.pruneBackoff.seconds.uint64))

      let backoff = Moment.fromNow(g.parameters.pruneBackoff)
      g.backingOff
        .mgetOrPut(topic, initTable[PeerID, Moment]())
        .mgetOrPut(peer.peerId, backoff) = backoff

      peer.behaviourPenalty += 0.1

      continue

    if peer.peerId notin g.peerStats:
      g.initPeerStats(peer)

    # not in the spec exactly, but let's avoid way too low score peers
    # other clients do it too also was an audit recommendation
    if peer.score < g.parameters.publishThreshold:
      continue

    # If they send us a graft before they send us a subscribe, what should
    # we do? For now, we add them to mesh but don't add them to gossipsub.
    if topic in g.topics:
      if g.mesh.peers(topic) < g.parameters.dHigh or peer.outbound:
        # In the spec, there's no mention of DHi here, but implicitly, a
        # peer will be removed from the mesh on next rebalance, so we don't want
        # this peer to push someone else out
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
        else:
          trace "peer already in mesh"
      else:
        trace "pruning grafting peer, mesh full", peer, score = peer.score, mesh = g.mesh.peers(topic)
        result.add(ControlPrune(
          topicID: topic,
          peers: g.peerExchangeList(topic),
          backoff: g.parameters.pruneBackoff.seconds.uint64))
    else:
      trace "peer grafting topic we're not interested in", topic
      # gossip 1.1, we do not send a control message prune anymore

proc handlePrune*(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    let topic = prune.topicID

    trace "peer pruned topic", peer, topic

    # add peer backoff
    if prune.backoff > 0:
      let
        backoff = Moment.fromNow((prune.backoff + BackoffSlackTime).int64.seconds)
        current = g.backingOff.getOrDefault(topic).getOrDefault(peer.peerId)
      if backoff > current:
        g.backingOff
          .mgetOrPut(topic, initTable[PeerID, Moment]())
          .mgetOrPut(peer.peerId, backoff) = backoff

    trace "pruning rpc received peer", peer, score = peer.score
    g.pruned(peer, topic)
    g.mesh.removePeer(topic, peer)

    # TODO peer exchange, we miss ambient peer discovery in libp2p, so we are blocked by that
    # another option could be to implement signed peer records
    ## if peer.score > g.parameters.gossipThreshold and prunes.peers.len > 0:

proc handleIHave*(g: GossipSub,
                 peer: PubSubPeer,
                 ihaves: seq[ControlIHave]): ControlIWant =
  if peer.score < g.parameters.gossipThreshold:
    trace "ihave: ignoring low score peer", peer, score = peer.score
  elif peer.iHaveBudget <= 0:
    trace "ihave: ignoring out of budget peer", peer, score = peer.score
  else:
    var deIhaves = ihaves.deduplicate()
    for ihave in deIhaves.mitems:
      trace "peer sent ihave",
        peer, topic = ihave.topicID, msgs = ihave.messageIDs
      if ihave.topicID in g.mesh:
        for m in ihave.messageIDs:
          let msgId = m & g.randomBytes
          if msgId notin g.seen:
            if peer.iHaveBudget > 0:
              result.messageIDs.add(m)
              dec peer.iHaveBudget
            else:
              return

    # shuffling result.messageIDs before sending it out to increase the likelihood
    # of getting an answer if the peer truncates the list due to internal size restrictions.
    shuffle(result.messageIDs)

proc handleIWant*(g: GossipSub,
                 peer: PubSubPeer,
                 iwants: seq[ControlIWant]): seq[Message] =
  if peer.score < g.parameters.gossipThreshold:
    trace "iwant: ignoring low score peer", peer, score = peer.score
  elif peer.iWantBudget <= 0:
    trace "iwant: ignoring out of budget peer", peer, score = peer.score
  else:
    var deIwants = iwants.deduplicate()
    for iwant in deIwants:
      for mid in iwant.messageIDs:
        trace "peer sent iwant", peer, messageID = mid
        let msg = g.mcache.get(mid)
        if msg.isSome:
          # avoid spam
          if peer.iWantBudget > 0:
            result.add(msg.get())
            dec peer.iWantBudget
          else:
            return
