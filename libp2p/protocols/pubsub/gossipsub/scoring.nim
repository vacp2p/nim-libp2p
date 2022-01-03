## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[tables, sets, options]
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

proc init*(_: type[TopicParams]): TopicParams =
  TopicParams(
    topicWeight: 0.0, # disabled by default
    timeInMeshWeight: 0.01,
    timeInMeshQuantum: 1.seconds,
    timeInMeshCap: 10.0,
    firstMessageDeliveriesWeight: 1.0,
    firstMessageDeliveriesDecay: 0.5,
    firstMessageDeliveriesCap: 10.0,
    meshMessageDeliveriesWeight: -1.0,
    meshMessageDeliveriesDecay: 0.5,
    meshMessageDeliveriesCap: 10,
    meshMessageDeliveriesThreshold: 1,
    meshMessageDeliveriesWindow: 5.milliseconds,
    meshMessageDeliveriesActivation: 10.seconds,
    meshFailurePenaltyWeight: -1.0,
    meshFailurePenaltyDecay: 0.5,
    invalidMessageDeliveriesWeight: -1.0,
    invalidMessageDeliveriesDecay: 0.5
  )

proc withPeerStats*(
    g: GossipSub,
    peerId: PeerId,
    action: proc (stats: var PeerStats) {.gcsafe, raises: [Defect].}) =
  ## Add or update peer statistics for a particular peer id - the statistics
  ## are retained across multiple connections until they expire
  g.peerStats.withValue(peerId, stats) do:
    action(stats[])
  do:
    action(g.peerStats.mgetOrPut(peerId, PeerStats(
      expire: Moment.now() + g.parameters.retainScore
    )))

func `/`(a, b: Duration): float64 =
  let
    fa = float64(a.nanoseconds)
    fb = float64(b.nanoseconds)
  fa / fb

func byScore*(x,y: PubSubPeer): int = system.cmp(x.score, y.score)

proc colocationFactor(g: GossipSub, peer: PubSubPeer): float64 =
  if peer.address.isNone():
    0.0
  else:
    let
      address = peer.address.get()
    g.peersInIP.mgetOrPut(address, initHashSet[PeerId]()).incl(peer.peerId)
    let
      ipPeers = g.peersInIP.getOrDefault(address).len().float64
    if ipPeers > g.parameters.ipColocationFactorThreshold:
      trace "colocationFactor over threshold", peer, address, ipPeers
      let over = ipPeers - g.parameters.ipColocationFactorThreshold
      over * over
    else:
      0.0

{.pop.}

proc disconnectPeer(g: GossipSub, peer: PubSubPeer) {.async.} =
  let agent =
    when defined(libp2p_agents_metrics):
      if peer.shortAgent.len > 0:
        peer.shortAgent
      else:
        "unknown"
    else:
      "unknown"
  libp2p_gossipsub_bad_score_disconnection.inc(labelValues = [agent])

  try:
    await g.switch.disconnect(peer.peerId)
  except CatchableError as exc: # Never cancelled
    trace "Failed to close connection", peer, error = exc.name, msg = exc.msg

{.push raises: [Defect].}

proc updateScores*(g: GossipSub) = # avoid async
  ## https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#the-score-function
  ##
  trace "updating scores", peers = g.peers.len

  let now = Moment.now()
  var evicting: seq[PeerId]

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
      score = 0.0

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

        score += topicScore * topicParams.topicWeight

      # Score metrics
      let agent =
        when defined(libp2p_agents_metrics):
          if peer.shortAgent.len > 0:
            peer.shortAgent
          else:
            "unknown"
        else:
          "unknown"
      libp2p_gossipsub_peers_score_firstMessageDeliveries.inc(info.firstMessageDeliveries, labelValues = [agent])
      libp2p_gossipsub_peers_score_meshMessageDeliveries.inc(info.meshMessageDeliveries, labelValues = [agent])
      libp2p_gossipsub_peers_score_meshFailurePenalty.inc(info.meshFailurePenalty, labelValues = [agent])
      libp2p_gossipsub_peers_score_invalidMessageDeliveries.inc(info.invalidMessageDeliveries, labelValues = [agent])

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

    score += peer.appScore * g.parameters.appSpecificWeight


    # The value of the parameter is the square of the counter and is mixed with a negative weight.
    score += peer.behaviourPenalty * peer.behaviourPenalty * g.parameters.behaviourPenaltyWeight

    let colocationFactor = g.colocationFactor(peer)
    score += colocationFactor * g.parameters.ipColocationFactorWeight

    # Score metrics
    let agent =
      when defined(libp2p_agents_metrics):
        if peer.shortAgent.len > 0:
          peer.shortAgent
        else:
          "unknown"
      else:
        "unknown"
    libp2p_gossipsub_peers_score_appScore.inc(peer.appScore, labelValues = [agent])
    libp2p_gossipsub_peers_score_behaviourPenalty.inc(peer.behaviourPenalty, labelValues = [agent])
    libp2p_gossipsub_peers_score_colocationFactor.inc(colocationFactor, labelValues = [agent])

    # decay behaviourPenalty
    peer.behaviourPenalty *= g.parameters.behaviourPenaltyDecay
    if peer.behaviourPenalty < g.parameters.decayToZero:
      peer.behaviourPenalty = 0

    peer.score = score

    # copy into stats the score to keep until expired
    stats.score = peer.score
    stats.appScore = peer.appScore
    stats.behaviourPenalty = peer.behaviourPenalty
    stats.expire = now + g.parameters.retainScore # refresh expiration

    trace "updated peer's score", peer, score = peer.score, n_topics, is_grafted

    if g.parameters.disconnectBadPeers and stats.score < g.parameters.graylistThreshold:
      debug "disconnecting bad score peer", peer, score = peer.score
      asyncSpawn(try: g.disconnectPeer(peer) except Exception as exc: raiseAssert exc.msg)

    libp2p_gossipsub_peers_scores.inc(peer.score, labelValues = [agent])

  for peer in evicting:
    g.peerStats.del(peer)

  trace "updated scores", peers = g.peers.len

proc punishInvalidMessage*(g: GossipSub, peer: PubSubPeer, topics: seq[string]) =
  for tt in topics:
    let t = tt
    if t notin g.topics:
      continue

    let tt = t
    # update stats
    g.withPeerStats(peer.peerId) do (stats: var PeerStats):
      stats.topicInfos.mgetOrPut(tt, TopicInfo()).invalidMessageDeliveries += 1

proc addCapped*[T](stat: var T, diff, cap: T) =
  stat += min(diff, cap - stat)

proc rewardDelivered*(
    g: GossipSub, peer: PubSubPeer, topics: openArray[string], first: bool) =
  for tt in topics:
    let t = tt
    if t notin g.topics:
      continue

    let tt = t
    let topicParams = g.topicParams.mgetOrPut(t, TopicParams.init())
                                            # if in mesh add more delivery score

    g.withPeerStats(peer.peerId) do (stats: var PeerStats):
      stats.topicInfos.withValue(tt, tstats):
        if tstats[].inMesh:
          if first:
            tstats[].firstMessageDeliveries.addCapped(
              1, topicParams.firstMessageDeliveriesCap)

          tstats[].meshMessageDeliveries.addCapped(
            1, topicParams.meshMessageDeliveriesCap)
      do: # make sure we don't loose this information
        stats.topicInfos[tt] = TopicInfo(meshMessageDeliveries: 1)
