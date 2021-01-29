## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sets, options, sequtils, strutils, random, algorithm]
import chronos, chronicles, metrics, bearssl
import ./pubsub,
       ./floodsub,
       ./pubsubpeer,
       ./peertable,
       ./mcache,
       ./timedcache,
       ./rpc/[messages, message],
       ../protocol,
       ../../stream/connection,
       ../../peerinfo,
       ../../peerid,
       ../../utility,
       ../../switch
import stew/results
export results

logScope:
  topics = "libp2p gossipsub"

const
  GossipSubCodec* = "/meshsub/1.1.0"
  GossipSubCodec_10* = "/meshsub/1.0.0"

# overlay parameters
const
  GossipSubD* = 6
  GossipSubDlo* = 4
  GossipSubDhi* = 12

# gossip parameters
const
  GossipSubHistoryLength* = 5
  GossipSubHistoryGossip* = 3

# heartbeat interval
  GossipSubHeartbeatInterval* = 1.seconds

# fanout ttl
const
  GossipSubFanoutTTL* = 1.minutes

# gossip parameters
const
  GossipBackoffPeriod* = 1.minutes

const
  BackoffSlackTime = 2 # seconds
  IWantPeerBudget = 25 # 25 messages per second ( reset every heartbeat )
  IHavePeerBudget = 10
  # the max amount of IHave to expose, not by spec, but go as example
  # rust sigp: https://github.com/sigp/rust-libp2p/blob/f53d02bc873fef2bf52cd31e3d5ce366a41d8a8c/protocols/gossipsub/src/config.rs#L572
  # go: https://github.com/libp2p/go-libp2p-pubsub/blob/08c17398fb11b2ab06ca141dddc8ec97272eb772/gossipsub.go#L155
  IHaveMaxLength = 5000

type
  TopicInfo* = object
    # gossip 1.1 related
    graftTime: Moment
    meshTime: Duration
    inMesh: bool
    meshMessageDeliveriesActive: bool
    firstMessageDeliveries: float64
    meshMessageDeliveries: float64
    meshFailurePenalty: float64
    invalidMessageDeliveries: float64

  TopicParams* = object
    topicWeight*: float64

    # p1
    timeInMeshWeight*: float64
    timeInMeshQuantum*: Duration
    timeInMeshCap*: float64

    # p2
    firstMessageDeliveriesWeight*: float64
    firstMessageDeliveriesDecay*: float64
    firstMessageDeliveriesCap*: float64

    # p3
    meshMessageDeliveriesWeight*: float64
    meshMessageDeliveriesDecay*: float64
    meshMessageDeliveriesThreshold*: float64
    meshMessageDeliveriesCap*: float64
    meshMessageDeliveriesActivation*: Duration
    meshMessageDeliveriesWindow*: Duration

    # p3b
    meshFailurePenaltyWeight*: float64
    meshFailurePenaltyDecay*: float64

    # p4
    invalidMessageDeliveriesWeight*: float64
    invalidMessageDeliveriesDecay*: float64

  PeerStats* = object
    topicInfos*: Table[string, TopicInfo]
    expire*: Moment # updated on disconnect, to retain scores until expire
    # the following are copies from PubSubPeer, in order to restore them on re-connection
    score*: float64 # a copy of the score to keep in case the peer is disconnected
    appScore*: float64 # application specific score
    behaviourPenalty*: float64 # the eventual penalty score

  GossipSubParams* = object
    explicit: bool
    pruneBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float64
    d*: int
    dLow*: int
    dHigh*: int
    dScore*: int
    dOut*: int
    dLazy*: int

    heartbeatInterval*: Duration

    historyLength*: int
    historyGossip*: int

    fanoutTTL*: Duration
    seenTTL*: Duration

    gossipThreshold*: float64
    publishThreshold*: float64
    graylistThreshold*: float64
    acceptPXThreshold*: float64
    opportunisticGraftThreshold*: float64
    decayInterval*: Duration
    decayToZero*: float64
    retainScore*: Duration

    appSpecificWeight*: float64
    ipColocationFactorWeight*: float64
    ipColocationFactorThreshold*: float64
    behaviourPenaltyWeight*: float64
    behaviourPenaltyDecay*: float64

    directPeers*: Table[PeerId, seq[MultiAddress]]

    disconnectBadPeers*: bool

  BackoffTable = Table[string, Table[PeerID, Moment]]

  GossipSub* = ref object of FloodSub
    mesh*: PeerTable                           # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable                         # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable                      # peers that are subscribed to a topic
    explicit*: PeerTable                       # directpeers that we keep alive explicitly
    backingOff*: BackoffTable                  # peers to backoff from when replenishing the mesh
    lastFanoutPubSub*: Table[string, Moment]   # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]  # pending gossip
    control*: Table[string, ControlMessage]    # pending control messages
    mcache*: MCache                            # messages cache
    heartbeatFut: Future[void]                 # cancellation future for heartbeat interval
    heartbeatRunning: bool

    peerStats: Table[PeerID, PeerStats]
    parameters*: GossipSubParams
    topicParams*: Table[string, TopicParams]
    directPeersLoop: Future[void]
    peersInIP: Table[MultiAddress, HashSet[PubSubPeer]]

    heartbeatEvents*: seq[AsyncEvent]

    randomBytes: seq[byte]

  MeshMetrics = object
    # scratch buffers for metrics
    otherPeersPerTopicMesh: int64
    otherPeersPerTopicFanout: int64
    otherPeersPerTopicGossipsub: int64
    underDlowTopics: int64
    underDoutTopics: int64
    underDhighAboveDlowTopics: int64
    noPeersTopics: int64


# the following 3 metrics are updated only inside rebalanceMesh
# this is the most reliable place and rebalance anyway happens every heartbeat
declareGauge(libp2p_gossipsub_peers_per_topic_mesh,
  "gossipsub peers per topic in mesh",
  labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_fanout,
  "gossipsub peers per topic in fanout",
  labels = ["topic"])
declareGauge(libp2p_gossipsub_peers_per_topic_gossipsub,
  "gossipsub peers per topic in gossipsub",
  labels = ["topic"])

declareCounter(libp2p_gossipsub_failed_publish, "number of failed publish")
declareGauge(libp2p_gossipsub_cache_window_size, "the number of messages in the cache")
declareGauge(libp2p_gossipsub_peers_scores, "the scores of the peers in gossipsub", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_firstMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_meshMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_meshFailurePenalty, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_invalidMessageDeliveries, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_appScore, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_behaviourPenalty, "Detailed gossipsub scoring metric", labels = ["agent"])
declareGauge(libp2p_gossipsub_peers_score_colocationFactor, "Detailed gossipsub scoring metric", labels = ["agent"])
declareCounter(libp2p_gossipsub_bad_score_disconnection, "the number of peers disconnected by gossipsub", labels = ["agent"])
declareGauge(libp2p_gossipsub_under_dlow_topics, "number of topics below dlow")
declareGauge(libp2p_gossipsub_under_dout_topics, "number of topics below dout")
declareGauge(libp2p_gossipsub_under_dhigh_above_dlow_topics, "number of topics below dhigh but above dlow")
declareGauge(libp2p_gossipsub_no_peers_topics, "number of topics without peers available")
declareCounter(libp2p_gossipsub_above_dhigh_condition, "number of above dhigh pruning branches ran", labels = ["topic"])
declareCounter(libp2p_gossipsub_invalid_topic_subscription, "number of invalid topic subscriptions that happened")

proc init*(_: type[GossipSubParams]): GossipSubParams =
  GossipSubParams(
      explicit: true,
      pruneBackoff: 1.minutes,
      floodPublish: true,
      gossipFactor: 0.25,
      d: GossipSubD,
      dLow: GossipSubDlo,
      dHigh: GossipSubDhi,
      dScore: GossipSubDlo,
      dOut: GossipSubDlo - 1, # DLow - 1
      dLazy: GossipSubD, # Like D
      heartbeatInterval: GossipSubHeartbeatInterval,
      historyLength: GossipSubHistoryLength,
      historyGossip: GossipSubHistoryGossip,
      fanoutTTL: GossipSubFanoutTTL,
      seenTTL: 2.minutes,
      gossipThreshold: -10,
      publishThreshold: -100,
      graylistThreshold: -10000,
      opportunisticGraftThreshold: 0,
      decayInterval: 1.seconds,
      decayToZero: 0.01,
      retainScore: 10.seconds,
      appSpecificWeight: 0.0,
      ipColocationFactorWeight: 0.0,
      ipColocationFactorThreshold: 1.0,
      behaviourPenaltyWeight: -1.0,
      behaviourPenaltyDecay: 0.999,
      disconnectBadPeers: false
    )

proc validateParameters*(parameters: GossipSubParams): Result[void, cstring] =
  if  (parameters.dOut >= parameters.dLow) or
      (parameters.dOut > (parameters.d div 2)):
    err("gossipsub: dOut parameter error, Number of outbound connections to keep in the mesh. Must be less than D_lo and at most D/2")
  elif parameters.gossipThreshold >= 0:
    err("gossipsub: gossipThreshold parameter error, Must be < 0")
  elif parameters.publishThreshold >= parameters.gossipThreshold:
    err("gossipsub: publishThreshold parameter error, Must be < gossipThreshold")
  elif parameters.graylistThreshold >= parameters.publishThreshold:
    err("gossipsub: graylistThreshold parameter error, Must be < publishThreshold")
  elif parameters.acceptPXThreshold < 0:
    err("gossipsub: acceptPXThreshold parameter error, Must be >= 0")
  elif parameters.opportunisticGraftThreshold < 0:
    err("gossipsub: opportunisticGraftThreshold parameter error, Must be >= 0")
  elif parameters.decayToZero > 0.5 or parameters.decayToZero <= 0.0:
    err("gossipsub: decayToZero parameter error, Should be close to 0.0")
  elif parameters.appSpecificWeight < 0:
    err("gossipsub: appSpecificWeight parameter error, Must be positive")
  elif parameters.ipColocationFactorWeight > 0:
    err("gossipsub: ipColocationFactorWeight parameter error, Must be negative or 0")
  elif parameters.ipColocationFactorThreshold < 1.0:
    err("gossipsub: ipColocationFactorThreshold parameter error, Must be at least 1")
  elif parameters.behaviourPenaltyWeight >= 0:
    err("gossipsub: behaviourPenaltyWeight parameter error, Must be negative")
  elif parameters.behaviourPenaltyDecay < 0 or parameters.behaviourPenaltyDecay >= 1:
    err("gossipsub: behaviourPenaltyDecay parameter error, Must be between 0 and 1")
  else:
    ok()

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

proc validateParameters*(parameters: TopicParams): Result[void, cstring] =
  if parameters.timeInMeshWeight <= 0.0 or parameters.timeInMeshWeight > 1.0:
    err("gossipsub: timeInMeshWeight parameter error, Must be a small positive value")
  elif parameters.timeInMeshCap <= 0.0:
    err("gossipsub: timeInMeshCap parameter error, Should be a positive value")
  elif parameters.firstMessageDeliveriesWeight <= 0.0:
    err("gossipsub: firstMessageDeliveriesWeight parameter error, Should be a positive value")
  elif parameters.meshMessageDeliveriesWeight >= 0.0:
    err("gossipsub: meshMessageDeliveriesWeight parameter error, Should be a negative value")
  elif parameters.meshMessageDeliveriesThreshold <= 0.0:
    err("gossipsub: meshMessageDeliveriesThreshold parameter error, Should be a positive value")
  elif parameters.meshMessageDeliveriesCap < parameters.meshMessageDeliveriesThreshold:
    err("gossipsub: meshMessageDeliveriesCap parameter error, Should be >= meshMessageDeliveriesThreshold")
  elif parameters.meshFailurePenaltyWeight >= 0.0:
    err("gossipsub: meshFailurePenaltyWeight parameter error, Should be a negative value")
  elif parameters.invalidMessageDeliveriesWeight >= 0.0:
    err("gossipsub: invalidMessageDeliveriesWeight parameter error, Should be a negative value")
  else:
    ok()

func byScore(x,y: PubSubPeer): int = system.cmp(x.score, y.score)

method init*(g: GossipSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##
    try:
      await g.handleConn(conn, proto)
    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
      trace "Unexpected cancellation in gossipsub handler", conn
    except CatchableError as exc:
      trace "GossipSub handler leaks an error", exc = exc.msg, conn

  g.handler = handler
  g.codecs &= GossipSubCodec
  g.codecs &= GossipSubCodec_10

proc initPeerStats(g: GossipSub, peer: PubSubPeer, stats: PeerStats = PeerStats()) =
  var initialStats = stats
  initialStats.expire = Moment.now() + g.parameters.retainScore
  g.peerStats[peer.peerId] = initialStats
  peer.iWantBudget = IWantPeerBudget
  peer.iHaveBudget = IHavePeerBudget

method onNewPeer(g: GossipSub, peer: PubSubPeer) =
  if peer.peerId notin g.peerStats:
    g.initPeerStats(peer)
  else:
    # we knew this peer
    # restore previously stored score
    let stats = g.peerStats[peer.peerId]
    peer.score = stats.score
    peer.appScore = stats.appScore
    peer.behaviourPenalty = stats.behaviourPenalty

proc grafted(g: GossipSub, p: PubSubPeer, topic: string) =
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

proc pruned(g: GossipSub, p: PubSubPeer, topic: string) =
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

proc peerExchangeList(g: GossipSub, topic: string): seq[PeerInfoMsg] =
  var peers = g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()).toSeq()
  peers.keepIf do (x: PubSubPeer) -> bool:
      x.score >= 0.0
  # by spec, larger then Dhi, but let's put some hard caps
  peers.setLen(min(peers.len, g.parameters.dHigh * 2))
  peers.map do (x: PubSubPeer) -> PeerInfoMsg:
    PeerInfoMsg(peerID: x.peerId.getBytes())

proc replenishFanout(g: GossipSub, topic: string) =
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

method onPubSubPeerEvent*(p: GossipSub, peer: PubsubPeer, event: PubSubPeerEvent) {.gcsafe.} =
  case event.kind
  of PubSubPeerEventKind.Connected:
    discard
  of PubSubPeerEventKind.Disconnected:
    # If a send connection is lost, it's better to remove peer from the mesh -
    # if it gets reestablished, the peer will be readded to the mesh, and if it
    # doesn't, well.. then we hope the peer is going away!
    for topic, peers in p.mesh.mpairs():
      p.pruned(peer, topic)
      peers.excl(peer)
    for _, peers in p.fanout.mpairs():
      peers.excl(peer)

  procCall FloodSub(p).onPubSubPeerEvent(peer, event)

proc commitMetrics(metrics: var MeshMetrics) =
  libp2p_gossipsub_under_dlow_topics.set(metrics.underDlowTopics)
  libp2p_gossipsub_no_peers_topics.set(metrics.noPeersTopics)
  libp2p_gossipsub_under_dout_topics.set(metrics.underDoutTopics)
  libp2p_gossipsub_under_dhigh_above_dlow_topics.set(metrics.underDhighAboveDlowTopics)
  libp2p_gossipsub_peers_per_topic_gossipsub.set(metrics.otherPeersPerTopicGossipsub, labelValues = ["other"])
  libp2p_gossipsub_peers_per_topic_fanout.set(metrics.otherPeersPerTopicFanout, labelValues = ["other"])
  libp2p_gossipsub_peers_per_topic_mesh.set(metrics.otherPeersPerTopicMesh, labelValues = ["other"])

proc rebalanceMesh(g: GossipSub, topic: string, metrics: ptr MeshMetrics = nil) =
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

func `/`(a, b: Duration): float64 =
  let
    fa = float64(a.nanoseconds)
    fb = float64(b.nanoseconds)
  fa / fb

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

  if peer.sendConn != nil:
    try:
      await g.switch.disconnect(peer.peerId)
    except CancelledError:
      raise
    except CatchableError as exc:
      trace "Failed to close connection", peer, error = exc.name, msg = exc.msg

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

proc updateScores(g: GossipSub) = # avoid async
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

proc handleBackingOff(t: var BackoffTable, topic: string) =
  let now = Moment.now()
  var expired = toSeq(t.getOrDefault(topic).pairs())
  expired.keepIf do (pair: tuple[peer: PeerID, expire: Moment]) -> bool:
    now >= pair.expire
  for (peer, _) in expired:
    t.mgetOrPut(topic, initTable[PeerID, Moment]()).del(peer)

proc heartbeat(g: GossipSub) {.async.} =
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

method unsubscribePeer*(g: GossipSub, peer: PeerID) =
  ## handle peer disconnects
  ##

  trace "unsubscribing gossipsub peer", peer
  let pubSubPeer = g.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    trace "no peer to unsubscribe", peer
    return

  # remove from peer IPs collection too
  if pubSubPeer.sendConn != nil:
    g.peersInIP.withValue(pubSubPeer.sendConn.observedAddr, s):
      s[].excl(pubSubPeer)
      if s[].len == 0:
        g.peersInIP.del(pubSubPeer.sendConn.observedAddr)

  for t in toSeq(g.gossipsub.keys):
    g.gossipsub.removePeer(t, pubSubPeer)
    # also try to remove from explicit table here
    g.explicit.removePeer(t, pubSubPeer)

  for t in toSeq(g.mesh.keys):
    trace "pruning unsubscribing peer", pubSubPeer, score = pubSubPeer.score
    g.pruned(pubSubPeer, t)
    g.mesh.removePeer(t, pubSubPeer)

  for t in toSeq(g.fanout.keys):
    g.fanout.removePeer(t, pubSubPeer)

  g.peerStats.withValue(peer, stats):
    stats[].expire = Moment.now() + g.parameters.retainScore
    for topic, info in stats[].topicInfos.mpairs:
      info.firstMessageDeliveries = 0

  procCall FloodSub(g).unsubscribePeer(peer)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peer: PubSubPeer) {.gcsafe.} =
  logScope:
    peer
    topic

  # this is a workaround for a race condition
  # that can happen if we disconnect the peer very early
  # in the future we might use this as a test case
  # and eventually remove this workaround
  if subscribe and peer.peerId notin g.peers:
    trace "ignoring unknown peer"
    return

  if subscribe and not(isNil(g.subscriptionValidator)) and not(g.subscriptionValidator(topic)):
    # this is a violation, so warn should be in order
    trace "ignoring invalid topic subscription", topic, peer
    libp2p_gossipsub_invalid_topic_subscription.inc()
    return

  if subscribe:
    trace "peer subscribed to topic"

    # subscribe remote peer to the topic
    discard g.gossipsub.addPeer(topic, peer)
    if peer.peerId in g.parameters.directPeers:
      discard g.explicit.addPeer(topic, peer)
  else:
    trace "peer unsubscribed from topic"

    # unsubscribe remote peer from the topic
    g.gossipsub.removePeer(topic, peer)
    g.mesh.removePeer(topic, peer)
    g.fanout.removePeer(topic, peer)
    if peer.peerId in g.parameters.directPeers:
      g.explicit.removePeer(topic, peer)

  trace "gossip peers", peers = g.gossipsub.peers(topic), topic

proc punishInvalidMessage(g: GossipSub, peer: PubSubPeer, topics: seq[string]) =
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


proc handleGraft(g: GossipSub,
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

proc handlePrune(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
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

proc handleIHave(g: GossipSub,
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

proc handleIWant(g: GossipSub,
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

method rpcHandler*(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsg: RPCMsg) {.async.} =
  await procCall PubSub(g).rpcHandler(peer, rpcMsg)

  for msg in rpcMsg.messages:                         # for every message
    let msgId = g.msgIdProvider(msg)

    # avoid the remote peer from controlling the seen table hashing
    # by adding random bytes to the ID we ensure we randomize the IDs
    # we do only for seen as this is the great filter from the external world
    if g.seen.put(msgId & g.randomBytes):
      trace "Dropping already-seen message", msgId = shortLog(msgId), peer

      # make sure to update score tho before continuing
      for t in msg.topicIDs:
        if t notin g.topics:
          continue
                         # for every topic in the message
        let topicParams = g.topicParams.mgetOrPut(t, TopicParams.init())
                                                # if in mesh add more delivery score
        g.peerStats.withValue(peer.peerId, pstats):
          pstats[].topicInfos.withValue(t, stats):
            if stats[].inMesh:
              # TODO: take into account meshMessageDeliveriesWindow
              # score only if messages are not too old.
              stats[].meshMessageDeliveries += 1
              if stats[].meshMessageDeliveries > topicParams.meshMessageDeliveriesCap:
                stats[].meshMessageDeliveries = topicParams.meshMessageDeliveriesCap
          do: # make sure we don't loose this information
            pstats[].topicInfos[t] = TopicInfo(meshMessageDeliveries: 1)
        do: # make sure we don't loose this information
          g.initPeerStats(peer) do:
            var stats = PeerStats()
            stats.topicInfos[t] = TopicInfo(meshMessageDeliveries: 1)
            stats

      # onto the next message
      continue

    # avoid processing messages we are not interested in
    if msg.topicIDs.allIt(it notin g.topics):
      debug "Dropping message of topic without subscription", msgId = shortLog(msgId), peer
      continue

    if (msg.signature.len > 0 or g.verifySignature) and not msg.verify():
      # always validate if signature is present or required
      debug "Dropping message due to failed signature verification",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIDs)
      continue

    if msg.seqno.len > 0 and msg.seqno.len != 8:
      # if we have seqno should be 8 bytes long
      debug "Dropping message due to invalid seqno length",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIDs)
      continue

    # g.anonymize needs no evaluation when receiving messages
    # as we have a "lax" policy and allow signed messages

    let validation = await g.validate(msg)
    case validation
    of ValidationResult.Reject:
      debug "Dropping message after validation, reason: reject",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIDs)
      continue
    of ValidationResult.Ignore:
      debug "Dropping message after validation, reason: ignore",
        msgId = shortLog(msgId), peer
      continue
    of ValidationResult.Accept:
      discard

    # store in cache only after validation
    g.mcache.put(msgId, msg)

    var toSendPeers = initHashSet[PubSubPeer]()
    for t in msg.topicIDs:                      # for every topic in the message
      if t notin g.topics:
        continue

      let topicParams = g.topicParams.mgetOrPut(t, TopicParams.init())

      g.peerStats.withValue(peer.peerId, pstats):
        pstats[].topicInfos.withValue(t, stats):
                                                    # contribute to peer score first delivery
          stats[].firstMessageDeliveries += 1
          if stats[].firstMessageDeliveries > topicParams.firstMessageDeliveriesCap:
            stats[].firstMessageDeliveries = topicParams.firstMessageDeliveriesCap

                                                    # if in mesh add more delivery score
          if stats[].inMesh:
            stats[].meshMessageDeliveries += 1
            if stats[].meshMessageDeliveries > topicParams.meshMessageDeliveriesCap:
              stats[].meshMessageDeliveries = topicParams.meshMessageDeliveriesCap
        do: # make sure we don't loose this information
          pstats[].topicInfos[t] = TopicInfo(firstMessageDeliveries: 1, meshMessageDeliveries: 1)
      do: # make sure we don't loose this information
        g.initPeerStats(peer) do:
          var stats = PeerStats()
          stats.topicInfos[t] = TopicInfo(firstMessageDeliveries: 1, meshMessageDeliveries: 1)
          stats

      g.floodsub.withValue(t, peers): toSendPeers.incl(peers[])
      g.mesh.withValue(t, peers): toSendPeers.incl(peers[])

      await handleData(g, t, msg.data)

    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    let sendingTo = toSeq(toSendPeers)
    g.broadcast(sendingTo, RPCMsg(messages: @[msg]))
    trace "forwared message to peers", peers = sendingTo.len, msgId, peer
    for topic in msg.topicIDs:
      if g.knownTopics.contains(topic):
        libp2p_pubsub_messages_rebroadcasted.inc(sendingTo.len.int64, labelValues = [topic])
      else:
        libp2p_pubsub_messages_rebroadcasted.inc(sendingTo.len.int64, labelValues = ["generic"])

  if rpcMsg.control.isSome:
    let control = rpcMsg.control.get()
    g.handlePrune(peer, control.prune)

    var respControl: ControlMessage
    respControl.iwant.add(g.handleIHave(peer, control.ihave))
    respControl.prune.add(g.handleGraft(peer, control.graft))
    let messages = g.handleIWant(peer, control.iwant)

    if respControl.graft.len > 0 or respControl.prune.len > 0 or
      respControl.ihave.len > 0 or messages.len > 0:
      # iwant and prunes from here, also messages

      for smsg in messages:
        for topic in smsg.topicIDs:
          if g.knownTopics.contains(topic):
            libp2p_pubsub_broadcast_messages.inc(labelValues = [topic])
          else:
            libp2p_pubsub_broadcast_messages.inc(labelValues = ["generic"])
      libp2p_pubsub_broadcast_iwant.inc(respControl.iwant.len.int64)
      for prune in respControl.prune:
        if g.knownTopics.contains(prune.topicID):
          libp2p_pubsub_broadcast_prune.inc(labelValues = [prune.topicID])
        else:
          libp2p_pubsub_broadcast_prune.inc(labelValues = ["generic"])
      trace "sending control message", msg = shortLog(respControl), peer
      g.send(
        peer,
        RPCMsg(control: some(respControl), messages: messages))

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) =
  procCall PubSub(g).subscribe(topic, handler)

  # if we have a fanout on this topic break it
  if topic in g.fanout:
    g.fanout.del(topic)

  # rebalance but don't update metrics here, we do that only in the heartbeat
  g.rebalanceMesh(topic, metrics = nil)

proc unsubscribe*(g: GossipSub, topic: string) =
  var
    msg = RPCMsg.withSubs(@[topic], subscribe = false)
    gpeers = g.gossipsub.getOrDefault(topic)

  if topic in g.mesh:
    let mpeers = g.mesh.getOrDefault(topic)

    # remove mesh peers from gpeers, we send 2 different messages
    gpeers = gpeers - mpeers
    # send to peers NOT in mesh first
    g.broadcast(toSeq(gpeers), msg)

    for peer in mpeers:
      trace "pruning unsubscribeAll call peer", peer, score = peer.score
      g.pruned(peer, topic)

    g.mesh.del(topic)

    msg.control =
      some(ControlMessage(prune:
        @[ControlPrune(topicID: topic,
          peers: g.peerExchangeList(topic),
          backoff: g.parameters.pruneBackoff.seconds.uint64)]))

    # send to peers IN mesh now
    g.broadcast(toSeq(mpeers), msg)
  else:
    g.broadcast(toSeq(gpeers), msg)

  g.topicParams.del(topic)

method unsubscribeAll*(g: GossipSub, topic: string) =
  g.unsubscribe(topic)
  # finally let's remove from g.topics, do that by calling PubSub
  procCall PubSub(g).unsubscribeAll(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) =
  procCall PubSub(g).unsubscribe(topics)

  for (topic, handler) in topics:
    # delete from mesh only if no handlers are left
    # (handlers are removed in pubsub unsubscribe above)
    if topic notin g.topics:
      g.unsubscribe(topic)

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte]): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data)

  logScope:
    topic

  trace "Publishing message on topic", data = data.shortLog

  if topic.len <= 0: # data could be 0/empty
    debug "Empty topic, skipping publish"
    return 0

  var peers: HashSet[PubSubPeer]

  if g.parameters.floodPublish:
    # With flood publishing enabled, the mesh is used when propagating messages from other peers,
    # but a peer's own messages will always be published to all known peers in the topic.
    for peer in g.gossipsub.getOrDefault(topic):
      if peer.score >= g.parameters.publishThreshold:
        trace "publish: including flood/high score peer", peer
        peers.incl(peer)

  # add always direct peers
  peers.incl(g.explicit.getOrDefault(topic))

  if topic in g.topics: # if we're subscribed use the mesh
    peers.incl(g.mesh.getOrDefault(topic))
  else: # not subscribed, send to fanout peers
    # try optimistically
    peers.incl(g.fanout.getOrDefault(topic))
    if peers.len == 0:
      # ok we had nothing.. let's try replenish inline
      g.replenishFanout(topic)
      peers.incl(g.fanout.getOrDefault(topic))

    # even if we couldn't publish,
    # we still attempted to publish
    # on the topic, so it makes sense
    # to update the last topic publish
    # time
    g.lastFanoutPubSub[topic] = Moment.fromNow(g.parameters.fanoutTTL)

  if peers.len == 0:
    notice "No peers for topic, skipping publish"
    # skipping topic as our metrics finds that heavy
    libp2p_gossipsub_failed_publish.inc()
    return 0

  inc g.msgSeqno
  let
    msg =
      if g.anonymize:
        Message.init(none(PeerInfo), data, topic, none(uint64), false)
      else:
        Message.init(some(g.peerInfo), data, topic, some(g.msgSeqno), g.sign)
    msgId = g.msgIdProvider(msg)

  logScope: msgId = shortLog(msgId)

  trace "Created new message", msg = shortLog(msg), peers = peers.len

  if g.seen.put(msgId & g.randomBytes):
    # custom msgid providers might cause this
    trace "Dropping already-seen message"
    return 0

  g.mcache.put(msgId, msg)

  let peerSeq = toSeq(peers)
  g.broadcast(peerSeq, RPCMsg(messages: @[msg]))
  if g.knownTopics.contains(topic):
    libp2p_pubsub_messages_published.inc(peerSeq.len.int64, labelValues = [topic])
  else:
    libp2p_pubsub_messages_published.inc(peerSeq.len.int64, labelValues = ["generic"])

  trace "Published message to peers"

  return peers.len

proc maintainDirectPeers(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    for id, addrs in g.parameters.directPeers:
      let peer = g.peers.getOrDefault(id)
      if isNil(peer):
        trace "Attempting to dial a direct peer", peer = id
        try:
          # dial, internally connection will be stored
          let _ = await g.switch.dial(id, addrs, g.codecs)
          # populate the peer after it's connected
          discard g.getOrCreatePeer(id, g.codecs)
        except CancelledError:
          trace "Direct peer dial canceled"
          raise
        except CatchableError as exc:
          debug "Direct peer error dialing", msg = exc.msg

    await sleepAsync(1.minutes)

method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  if not g.heartbeatFut.isNil:
    warn "Starting gossipsub twice"
    return

  g.heartbeatRunning = true
  g.heartbeatFut = g.heartbeat()
  g.directPeersLoop = g.maintainDirectPeers()

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"
  if g.heartbeatFut.isNil:
    warn "Stopping gossipsub without starting it"
    return

  # stop heartbeat interval
  g.heartbeatRunning = false
  g.directPeersLoop.cancel()
  if not g.heartbeatFut.finished:
    trace "awaiting last heartbeat"
    await g.heartbeatFut
    trace "heartbeat stopped"
    g.heartbeatFut = nil

method initPubSub*(g: GossipSub) =
  procCall FloodSub(g).initPubSub()

  if not g.parameters.explicit:
    g.parameters = GossipSubParams.init()

  g.parameters.validateParameters().tryGet()

  randomize()

  # init the floodsub stuff here, we customize timedcache in gossip!
  g.floodsub = initTable[string, HashSet[PubSubPeer]]()
  g.seen = TimedCache[MessageID].init(g.parameters.seenTTL)

  # init gossip stuff
  g.mcache = MCache.init(g.parameters.historyGossip, g.parameters.historyLength)
  g.mesh = initTable[string, HashSet[PubSubPeer]]()     # meshes - topic to peer
  g.fanout = initTable[string, HashSet[PubSubPeer]]()   # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[PubSubPeer]]()# topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Moment]()  # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]()   # pending control messages
  var rng = newRng()
  g.randomBytes = newSeqUninitialized[byte](32)
  brHmacDrbgGenerate(rng[], g.randomBytes)
