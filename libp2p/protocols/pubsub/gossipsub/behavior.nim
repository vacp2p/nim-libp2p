## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, strutils, sequtils, sets, algorithm]
import random # for shuffle
import chronos, chronicles, metrics
import "."/[types, scoring]
import ".."/[pubsubpeer, peertable, timedcache, mcache, pubsub]
import "../rpc"/[messages]
import "../../.."/[peerid, multiaddress, utility, switch]

declareGauge(libp2p_gossipsub_cache_window_size, "the number of messages in the cache")
declareGauge(libp2p_gossipsub_peers_per_topic_mesh, "gossipsub peers per topic in mesh", labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_fanout, "gossipsub peers per topic in fanout", labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_gossipsub, "gossipsub peers per topic in gossipsub", labels = ["topic"])
declareGauge(libp2p_gossipsub_under_dlow_topics, "number of topics below dlow")
declareGauge(libp2p_gossipsub_under_dout_topics, "number of topics below dout")
declareGauge(libp2p_gossipsub_under_dhigh_above_dlow_topics, "number of topics below dhigh but above dlow")
declareGauge(libp2p_gossipsub_no_peers_topics, "number of topics without peers available")
declareCounter(libp2p_gossipsub_above_dhigh_condition, "number of above dhigh pruning branches ran", labels = ["topic"])

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

proc commitMetrics(metrics: var MeshMetrics) =
  libp2p_gossipsub_under_dlow_topics.set(metrics.underDlowTopics)
  libp2p_gossipsub_no_peers_topics.set(metrics.noPeersTopics)
  libp2p_gossipsub_under_dout_topics.set(metrics.underDoutTopics)
  libp2p_gossipsub_under_dhigh_above_dlow_topics.set(metrics.underDhighAboveDlowTopics)
  libp2p_gossipsub_peers_per_topic_gossipsub.set(metrics.otherPeersPerTopicGossipsub, labelValues = ["other"])
  libp2p_gossipsub_peers_per_topic_fanout.set(metrics.otherPeersPerTopicFanout, labelValues = ["other"])
  libp2p_gossipsub_peers_per_topic_mesh.set(metrics.otherPeersPerTopicMesh, labelValues = ["other"])

proc rebalanceMesh*(g: GossipSub, topic: string, metrics: ptr MeshMetrics = nil) =
  logScope:
    topic
    mesh = g.mesh.peers(topic)
    gossipsub = g.gossipsub.peers(topic)

  trace "rebalancing mesh"

  # create a mesh topic that we're subscribing to

  var
    prunes, grafts: seq[PubSubPeer]
    npeers = g.mesh.peers(topic)

  if npeers  < g.parameters.dLow:
    if not isNil(metrics):
      inc metrics[].underDlowTopics

    trace "replenishing mesh", peers = npeers
    # replenish the mesh if we're below Dlo
    var candidates = toSeq(
      g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
      g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
    ).filterIt(
      it.connected and
      # avoid negative score peers
      it.score >= 0.0 and
      # don't pick explicit peers
      it.peerId notin g.parameters.directPeers and
      # and avoid peers we are backing off
      it.peerId notin g.backingOff.getOrDefault(topic)
    )

    # shuffle anyway, score might be not used
    shuffle(candidates)

    # sort peers by score, high score first since we graft
    candidates.sort(byScore, SortOrder.Descending)

    # Graft peers so we reach a count of D
    candidates.setLen(min(candidates.len, g.parameters.d - npeers))

    trace "grafting", grafting = candidates.len

    if candidates.len == 0:
      if not isNil(metrics):
        inc metrics[].noPeersTopics
    else:
      for peer in candidates:
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
          grafts &= peer

  else:
    var meshPeers = toSeq(g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]()))
    meshPeers.keepIf do (x: PubSubPeer) -> bool: x.outbound
    if meshPeers.len < g.parameters.dOut:
      if not isNil(metrics):
        inc metrics[].underDoutTopics

      trace "replenishing mesh outbound quota", peers = g.mesh.peers(topic)

      var candidates = toSeq(
        g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
        g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
      ).filterIt(
        it.connected and
        # get only outbound ones
        it.outbound and
        # avoid negative score peers
        it.score >= 0.0 and
        # don't pick explicit peers
        it.peerId notin g.parameters.directPeers and
        # and avoid peers we are backing off
        it.peerId notin g.backingOff.getOrDefault(topic)
      )

      # shuffle anyway, score might be not used
      shuffle(candidates)

      # sort peers by score, high score first, we are grafting
      candidates.sort(byScore, SortOrder.Descending)

      # Graft peers so we reach a count of D
      candidates.setLen(min(candidates.len, g.parameters.dOut))

      trace "grafting outbound peers", topic, peers = candidates.len

      for peer in candidates:
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
          grafts &= peer


  # get again npeers after possible grafts
  npeers = g.mesh.peers(topic)
  if npeers > g.parameters.dHigh:
    if not isNil(metrics):
      if g.knownTopics.contains(topic):
        libp2p_gossipsub_above_dhigh_condition.inc(labelValues = [topic])
      else:
        libp2p_gossipsub_above_dhigh_condition.inc(labelValues = ["other"])

    # prune peers if we've gone over Dhi
    prunes = toSeq(g.mesh[topic])
    # avoid pruning peers we are currently grafting in this heartbeat
    prunes.keepIf do (x: PubSubPeer) -> bool: x notin grafts

    # shuffle anyway, score might be not used
    shuffle(prunes)

    # sort peers by score (inverted), pruning, so low score peers are on top
    prunes.sort(byScore, SortOrder.Ascending)

    # keep high score peers
    if prunes.len > g.parameters.dScore:
      prunes.setLen(prunes.len - g.parameters.dScore)

      # collect inbound/outbound info
      var outbound: seq[PubSubPeer]
      var inbound: seq[PubSubPeer]
      for peer in prunes:
        if peer.outbound:
          outbound &= peer
        else:
          inbound &= peer

      let
        meshOutbound = prunes.countIt(it.outbound)
        maxOutboundPrunes = meshOutbound - g.parameters.dOut

      # ensure that there are at least D_out peers first and rebalance to g.d after that
      outbound.setLen(min(outbound.len, max(0, maxOutboundPrunes)))

      # concat remaining outbound peers
      prunes = inbound & outbound

      let pruneLen = prunes.len - g.parameters.d
      if pruneLen > 0:
        # Ok we got some peers to prune,
        # for this heartbeat let's prune those
        shuffle(prunes)
        prunes.setLen(pruneLen)

      trace "pruning", prunes = prunes.len
      for peer in prunes:
        trace "pruning peer on rebalance", peer, score = peer.score
        g.pruned(peer, topic)
        g.mesh.removePeer(topic, peer)
  elif npeers > g.parameters.dLow and not isNil(metrics):
    inc metrics[].underDhighAboveDlowTopics

  # opportunistic grafting, by spec mesh should not be empty...
  if g.mesh.peers(topic) > 1:
    var peers = toSeq(g.mesh[topic])
    # grafting so high score has priority
    peers.sort(byScore, SortOrder.Descending)
    let medianIdx = peers.len div 2
    let median = peers[medianIdx]
    if median.score < g.parameters.opportunisticGraftThreshold:
      trace "median score below opportunistic threshold", score = median.score
      var avail = toSeq(
        g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
        g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
      )

      avail.keepIf do (x: PubSubPeer) -> bool:
        # avoid negative score peers
        x.score >= median.score and
        # don't pick explicit peers
        x.peerId notin g.parameters.directPeers and
        # and avoid peers we are backing off
        x.peerId notin g.backingOff.getOrDefault(topic)

      # by spec, grab only 2
      if avail.len > 2:
        avail.setLen(2)

      for peer in avail:
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          grafts &= peer
          trace "opportunistic grafting", peer

  if not isNil(metrics):
    if g.knownTopics.contains(topic):
      libp2p_gossipsub_peers_per_topic_gossipsub
        .set(g.gossipsub.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(topic).int64, labelValues = [topic])
    else:
      metrics[].otherPeersPerTopicGossipsub += g.gossipsub.peers(topic).int64
      metrics[].otherPeersPerTopicFanout += g.fanout.peers(topic).int64
      metrics[].otherPeersPerTopicMesh += g.mesh.peers(topic).int64

  trace "mesh balanced"

  # Send changes to peers after table updates to avoid stale state
  if grafts.len > 0:
    let graft = RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))
    g.broadcast(grafts, graft)
  if prunes.len > 0:
    let prune = RPCMsg(control: some(ControlMessage(
      prune: @[ControlPrune(
        topicID: topic,
        peers: g.peerExchangeList(topic),
        backoff: g.parameters.pruneBackoff.seconds.uint64)])))
    g.broadcast(prunes, prune)

proc dropFanoutPeers(g: GossipSub) =
  # drop peers that we haven't published to in
  # GossipSubFanoutTTL seconds
  let now = Moment.now()
  for topic in toSeq(g.lastFanoutPubSub.keys):
    let val = g.lastFanoutPubSub[topic]
    if now > val:
      g.fanout.del(topic)
      g.lastFanoutPubSub.del(topic)
      trace "dropping fanout topic", topic

proc replenishFanout*(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  logScope: topic
  trace "about to replenish fanout"

  if g.fanout.peers(topic) < g.parameters.dLow:
    trace "replenishing fanout", peers = g.fanout.peers(topic)
    if topic in g.gossipsub:
      for peer in g.gossipsub[topic]:
        if g.fanout.addPeer(topic, peer):
          if g.fanout.peers(topic) == g.parameters.d:
            break

  trace "fanout replenished with peers", peers = g.fanout.peers(topic)

proc getGossipPeers(g: GossipSub): Table[PubSubPeer, ControlMessage] {.gcsafe.} =
  ## gossip iHave messages to peers
  ##

  libp2p_gossipsub_cache_window_size.set(0)

  trace "getting gossip peers (iHave)"
  let topics = toHashSet(toSeq(g.mesh.keys)) + toHashSet(toSeq(g.fanout.keys))
  for topic in topics:
    if topic notin g.gossipsub:
      trace "topic not in gossip array, skipping", topicID = topic
      continue

    let mids = g.mcache.window(topic)
    if not(mids.len > 0):
      continue

    var midsSeq = toSeq(mids)

    libp2p_gossipsub_cache_window_size.inc(midsSeq.len.int64)

    # not in spec
    # similar to rust: https://github.com/sigp/rust-libp2p/blob/f53d02bc873fef2bf52cd31e3d5ce366a41d8a8c/protocols/gossipsub/src/behaviour.rs#L2101
    # and go https://github.com/libp2p/go-libp2p-pubsub/blob/08c17398fb11b2ab06ca141dddc8ec97272eb772/gossipsub.go#L582
    if midsSeq.len > IHaveMaxLength:
      shuffle(midsSeq)
      midsSeq.setLen(IHaveMaxLength)

    let
      ihave = ControlIHave(topicID: topic, messageIDs: midsSeq)
      mesh = g.mesh.getOrDefault(topic)
      fanout = g.fanout.getOrDefault(topic)
      gossipPeers = mesh + fanout
    var allPeers = toSeq(g.gossipsub.getOrDefault(topic))

    allPeers.keepIf do (x: PubSubPeer) -> bool:
      x.peerId notin g.parameters.directPeers and
      x notin gossipPeers and
      x.score >= g.parameters.gossipThreshold

    var target = g.parameters.dLazy
    let factor = (g.parameters.gossipFactor.float * allPeers.len.float).int
    if factor > target:
      target = min(factor, allPeers.len)

    if target < allPeers.len:
      shuffle(allPeers)
      allPeers.setLen(target)

    for peer in allPeers:
      if peer notin result:
        result[peer] = ControlMessage()
      result[peer].ihave.add(ihave)

proc heartbeat*(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat", instance = cast[int](g)

      # reset IWANT budget
      # reset IHAVE cap
      block:
        for peer in g.peers.values:
          peer.iWantBudget = IWantPeerBudget
          peer.iHaveBudget = IHavePeerBudget

      g.updateScores()

      var meshMetrics = MeshMetrics()

      for t in toSeq(g.topics.keys):
        # remove expired backoffs
        block:
          handleBackingOff(g.backingOff, t)

        # prune every negative score peer
        # do this before relance
        # in order to avoid grafted -> pruned in the same cycle
        let meshPeers = g.mesh.getOrDefault(t)
        var prunes: seq[PubSubPeer]
        for peer in meshPeers:
          if peer.score < 0.0:
            trace "pruning negative score peer", peer, score = peer.score
            g.pruned(peer, t)
            g.mesh.removePeer(t, peer)
            prunes &= peer
        if prunes.len > 0:
          let prune = RPCMsg(control: some(ControlMessage(
            prune: @[ControlPrune(
              topicID: t,
              peers: g.peerExchangeList(t),
              backoff: g.parameters.pruneBackoff.seconds.uint64)])))
          g.broadcast(prunes, prune)

        # pass by ptr in order to both signal we want to update metrics
        # and as well update the struct for each topic during this iteration
        g.rebalanceMesh(t, addr meshMetrics)

      commitMetrics(meshMetrics)

      g.dropFanoutPeers()

      # replenish known topics to the fanout
      for t in toSeq(g.fanout.keys):
        g.replenishFanout(t)

      let peers = g.getGossipPeers()
      for peer, control in peers:
        # only ihave from here
        for ihave in control.ihave:
          if g.knownTopics.contains(ihave.topicID):
            libp2p_pubsub_broadcast_ihave.inc(labelValues = [ihave.topicID])
          else:
            libp2p_pubsub_broadcast_ihave.inc(labelValues = ["generic"])
        g.send(peer, RPCMsg(control: some(control)))

      g.mcache.shift() # shift the cache
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "exception ocurred in gossipsub heartbeat", exc = exc.msg,
                                                       trace = exc.getStackTrace()

    for trigger in g.heartbeatEvents:
      trace "firing heartbeat event", instance = cast[int](g)
      trigger.fire()

    await sleepAsync(g.parameters.heartbeatInterval)
