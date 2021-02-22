## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, strutils, sets, algorithm]
import chronos, chronicles, metrics
import "."/[types]
import ".."/[pubsubpeer]
import "../../.."/[peerid, multiaddress, utility, switch]

declareGauge(libp2p_gossipsub_peers_scores, "the scores of the peers in gossipsub", labels = ["agent"])
declareCounter(libp2p_gossipsub_bad_score_disconnection, "the number of peers disconnected by gossipsub", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_firstMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_meshMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_meshFailurePenalty, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_invalidMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_appScore, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_behaviourPenalty, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_colocationFactor, "Detailed gossipsub scoring metric", labels = ["agent"])

proc initPeerStats*(g: GossipSub, peer: PubSubPeer, stats: PeerStats = PeerStats()) =
  var initialStats = stats
  initialStats.expire = Moment.now() + g.parameters.retainScore
  g.peerStats[peer.peerId] = initialStats
  peer.iWantBudget = IWantPeerBudget
  peer.iHaveBudget = IHavePeerBudget

func `/`(a, b: Duration): float64 =
  let
    fa = float64(a.nanoseconds)
    fb = float64(b.nanoseconds)
  fa / fb

func byScore*(x,y: PubSubPeer): int = system.cmp(x.score, y.score)

proc colocationFactor(g: GossipSub, peer: PubSubPeer): float64 =
  if peer.sendConn == nil:
    trace "colocationFactor, no connection", peer
    0.0
  else:
    let
      address = peer.sendConn.observedAddr

    g.peersInIP.mgetOrPut(address, initHashSet[PubSubPeer]()).incl(peer)
    if address notin g.peersInIP:
      g.peersInIP[address] = initHashSet[PubSubPeer]()
    g.peersInIP[address].incl(peer)

    let
      ipPeers = g.peersInIP[address]
      len = ipPeers.len.float64

    if len > g.parameters.ipColocationFactorThreshold:
      trace "colocationFactor over threshold", peer, address, len
      let over = len - g.parameters.ipColocationFactorThreshold
      over * over
    else:
      0.0

proc disconnectPeer(g: GossipSub, peer: PubSubPeer) {.async.} =
  when defined(libp2p_agents_metrics):
    let agent =
      block:
        if peer.shortAgent.len > 0:
          peer.shortAgent
        else:
          if peer.sendConn != nil:
            let shortAgent = peer.sendConn.peerInfo.agentVersion.split("/")[0].toLowerAscii()
            if KnownLibP2PAgentsSeq.contains(shortAgent):
              peer.shortAgent = shortAgent
            else:
              peer.shortAgent = "unknown"
            peer.shortAgent
          else:
            "unknown"
    libp2p_gossipsub_bad_score_disconnection.inc(labelValues = [agent])
  else:
    libp2p_gossipsub_bad_score_disconnection.inc(labelValues = ["unknown"])

  try:
    await g.switch.disconnect(peer.peerId)
  except CancelledError:
    raise
  except CatchableError as exc:
    trace "Failed to close connection", peer, error = exc.name, msg = exc.msg

proc updateScores*(g: GossipSub) = # avoid async
  trace "updating scores", peers = g.peers.len

  let now = Moment.now()
  var evicting: seq[PeerID]

  for peerId, stats in g.peerStats.mpairs:
    let peer = g.peers.getOrDefault(peerId)
    if isNil(peer) or not(peer.connected):
      if now > stats.expire:
        evicting.add(peerId)
        trace "evicted peer from memory", peer = peerId
      continue

    trace "updating peer score", peer

    var
      n_topics = 0
      is_grafted = 0

    # Per topic
    for topic, topicParams in g.topicParams:
      var info = stats.topicInfos.getOrDefault(topic)
      inc n_topics

      # if weight is 0.0 avoid wasting time
      if topicParams.topicWeight != 0.0:
        # Scoring
        var topicScore = 0'f64

        if info.inMesh:
          inc is_grafted
          info.meshTime = now - info.graftTime
          if info.meshTime > topicParams.meshMessageDeliveriesActivation:
            info.meshMessageDeliveriesActive = true

          var p1 = info.meshTime / topicParams.timeInMeshQuantum
          if p1 > topicParams.timeInMeshCap:
            p1 = topicParams.timeInMeshCap
          trace "p1", peer, p1, topic, topicScore
          topicScore += p1 * topicParams.timeInMeshWeight
        else:
          info.meshMessageDeliveriesActive = false

        topicScore += info.firstMessageDeliveries * topicParams.firstMessageDeliveriesWeight
        trace "p2", peer, p2 = info.firstMessageDeliveries, topic, topicScore

        if info.meshMessageDeliveriesActive:
          if info.meshMessageDeliveries < topicParams.meshMessageDeliveriesThreshold:
            let deficit = topicParams.meshMessageDeliveriesThreshold - info.meshMessageDeliveries
            let p3 = deficit * deficit
            trace "p3", peer, p3, topic, topicScore
            topicScore += p3 * topicParams.meshMessageDeliveriesWeight

        topicScore += info.meshFailurePenalty * topicParams.meshFailurePenaltyWeight
        trace "p3b", peer, p3b = info.meshFailurePenalty, topic, topicScore

        topicScore += info.invalidMessageDeliveries * info.invalidMessageDeliveries * topicParams.invalidMessageDeliveriesWeight
        trace "p4", p4 = info.invalidMessageDeliveries * info.invalidMessageDeliveries, topic, topicScore

        trace "updated peer topic's scores", peer, topic, info, topicScore

        peer.score += topicScore * topicParams.topicWeight

      # Score metrics
      when defined(libp2p_agents_metrics):
        let agent =
          block:
            if peer.shortAgent.len > 0:
              peer.shortAgent
            else:
              if peer.sendConn != nil:
                let shortAgent = peer.sendConn.peerInfo.agentVersion.split("/")[0].toLowerAscii()
                if KnownLibP2PAgentsSeq.contains(shortAgent):
                  peer.shortAgent = shortAgent
                else:
                  peer.shortAgent = "unknown"
                peer.shortAgent
              else:
                "unknown"
        libp2p_gossipsub_peers_score_firstMessageDeliveries.inc(info.firstMessageDeliveries, labelValues = [agent])
        libp2p_gossipsub_peers_score_meshMessageDeliveries.inc(info.meshMessageDeliveries, labelValues = [agent])
        libp2p_gossipsub_peers_score_meshFailurePenalty.inc(info.meshFailurePenalty, labelValues = [agent])
        libp2p_gossipsub_peers_score_invalidMessageDeliveries.inc(info.invalidMessageDeliveries, labelValues = [agent])
      else:
        libp2p_gossipsub_peers_score_firstMessageDeliveries.inc(info.firstMessageDeliveries, labelValues = ["unknown"])
        libp2p_gossipsub_peers_score_meshMessageDeliveries.inc(info.meshMessageDeliveries, labelValues = ["unknown"])
        libp2p_gossipsub_peers_score_meshFailurePenalty.inc(info.meshFailurePenalty, labelValues = ["unknown"])
        libp2p_gossipsub_peers_score_invalidMessageDeliveries.inc(info.invalidMessageDeliveries, labelValues = ["unknown"])

      # Score decay
      info.firstMessageDeliveries *= topicParams.firstMessageDeliveriesDecay
      if info.firstMessageDeliveries < g.parameters.decayToZero:
        info.firstMessageDeliveries = 0

      info.meshMessageDeliveries *= topicParams.meshMessageDeliveriesDecay
      if info.meshMessageDeliveries < g.parameters.decayToZero:
        info.meshMessageDeliveries = 0

      info.meshFailurePenalty *= topicParams.meshFailurePenaltyDecay
      if info.meshFailurePenalty < g.parameters.decayToZero:
        info.meshFailurePenalty = 0

      info.invalidMessageDeliveries *= topicParams.invalidMessageDeliveriesDecay
      if info.invalidMessageDeliveries < g.parameters.decayToZero:
        info.invalidMessageDeliveries = 0

      # Wrap up
      # commit our changes, mgetOrPut does NOT work as wanted with value types (lent?)
      stats.topicInfos[topic] = info

    peer.score += peer.appScore * g.parameters.appSpecificWeight

    peer.score += peer.behaviourPenalty * peer.behaviourPenalty * g.parameters.behaviourPenaltyWeight

    let colocationFactor = g.colocationFactor(peer)
    peer.score += colocationFactor * g.parameters.ipColocationFactorWeight

    # Score metrics
    when defined(libp2p_agents_metrics):
      let agent =
        block:
          if peer.shortAgent.len > 0:
            peer.shortAgent
          else:
            if peer.sendConn != nil:
              let shortAgent = peer.sendConn.peerInfo.agentVersion.split("/")[0].toLowerAscii()
              if KnownLibP2PAgentsSeq.contains(shortAgent):
                peer.shortAgent = shortAgent
              else:
                peer.shortAgent = "unknown"
              peer.shortAgent
            else:
              "unknown"
      libp2p_gossipsub_peers_score_appScore.inc(peer.appScore, labelValues = [agent])
      libp2p_gossipsub_peers_score_behaviourPenalty.inc(peer.behaviourPenalty, labelValues = [agent])
      libp2p_gossipsub_peers_score_colocationFactor.inc(colocationFactor, labelValues = [agent])
    else:
      libp2p_gossipsub_peers_score_appScore.inc(peer.appScore, labelValues = ["unknown"])
      libp2p_gossipsub_peers_score_behaviourPenalty.inc(peer.behaviourPenalty, labelValues = ["unknown"])
      libp2p_gossipsub_peers_score_colocationFactor.inc(colocationFactor, labelValues = ["unknown"])

    # decay behaviourPenalty
    peer.behaviourPenalty *= g.parameters.behaviourPenaltyDecay
    if peer.behaviourPenalty < g.parameters.decayToZero:
      peer.behaviourPenalty = 0

    # copy into stats the score to keep until expired
    stats.score = peer.score
    stats.appScore = peer.appScore
    stats.behaviourPenalty = peer.behaviourPenalty
    stats.expire = Moment.now() + g.parameters.retainScore # refresh expiration
    assert(g.peerStats[peer.peerId].score == peer.score) # nim sanity check
    trace "updated peer's score", peer, score = peer.score, n_topics, is_grafted

    if g.parameters.disconnectBadPeers and stats.score < g.parameters.graylistThreshold:
      debug "disconnecting bad score peer", peer, score = peer.score
      asyncSpawn g.disconnectPeer(peer)

    when defined(libp2p_agents_metrics):
      libp2p_gossipsub_peers_scores.inc(peer.score, labelValues = [agent])
    else:
      libp2p_gossipsub_peers_scores.inc(peer.score, labelValues = ["unknown"])

  for peer in evicting:
    g.peerStats.del(peer)

  trace "updated scores", peers = g.peers.len

proc punishInvalidMessage*(g: GossipSub, peer: PubSubPeer, topics: seq[string]) =
  for t in topics:
    if t notin g.topics:
      continue

    # update stats
    g.peerStats.withValue(peer.peerId, stats):
      stats[].topicInfos.withValue(t, tstats):
        tstats[].invalidMessageDeliveries += 1
      do: # if we have no stats populate!
        stats[].topicInfos[t] = TopicInfo(invalidMessageDeliveries: 1)
    do: # if we have no stats populate!
      g.initPeerStats(peer) do:
        var stats = PeerStats()
        stats.topicInfos[t] = TopicInfo(invalidMessageDeliveries: 1)
        stats
