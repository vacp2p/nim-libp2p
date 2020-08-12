## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sets, options, sequtils, random, algorithm]
import chronos, chronicles, metrics
import pubsub,
       floodsub,
       pubsubpeer,
       peertable,
       mcache,
       timedcache,
       rpc/[messages, message],
       ../protocol,
       ../../peerinfo,
       ../../stream/connection,
       ../../peerid,
       ../../errors,
       ../../utility
import stew/results
export results

logScope:
  topics = "gossipsub"

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
  GossipBackoffPeriod* = 1.minutes

# heartbeat interval
const
  GossipSubHeartbeatInitialDelay* = 100.millis
  GossipSubHeartbeatInterval* = 1.seconds

# fanout ttl
const 
  GossipSubFanoutTTL* = 1.minutes

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

  GossipSubParams* = object
    pruneBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float64
    dScore*: int
    dOut*: int

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

  GossipSub* = ref object of FloodSub
    mesh*: PeerTable                           # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable                         # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable                      # peers that are subscribed to a topic
    explicit*: PeerTable                       # directpeers that we keep alive explicitly
    explicitPeers*: HashSet[PeerID]            # explicit (always connected/forward) peers
    lastFanoutPubSub*: Table[string, Moment]   # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]  # pending gossip
    control*: Table[string, ControlMessage]    # pending control messages
    mcache*: MCache                            # messages cache
    heartbeatFut: Future[void]                 # cancellation future for heartbeat interval
    heartbeatRunning: bool
    heartbeatLock: AsyncLock                   # heartbeat lock to prevent two consecutive concurrent heartbeats

    peerStats: Table[PubSubPeer, PeerStats]
    parameters*: GossipSubParams
    topicParams*: Table[string, TopicParams]

    heartbeatEvents*: seq[AsyncEvent]

    when not defined(release):
      prunedPeers: HashSet[PubSubPeer]

when defined(libp2p_expensive_metrics):
  declareGauge(libp2p_gossipsub_peers_per_topic_mesh,
    "gossipsub peers per topic in mesh",
    labels = ["topic"])

  declareGauge(libp2p_gossipsub_peers_per_topic_fanout,
    "gossipsub peers per topic in fanout",
    labels = ["topic"])

  declareGauge(libp2p_gossipsub_peers_per_topic_gossipsub,
    "gossipsub peers per topic in gossipsub",
    labels = ["topic"])

proc init*(_: type[GossipSubParams]): GossipSubParams =
  GossipSubParams(
      pruneBackoff: 1.minutes,
      floodPublish: true,
      gossipFactor: 0.25,
      dScore: 4,
      dOut: 2,
      gossipThreshold: -10,
      publishThreshold: -100,
      graylistThreshold: -10000,
      opportunisticGraftThreshold: 1,
      decayInterval: 1.seconds,
      decayToZero: 0.01,
      retainScore: 10.seconds,
      appSpecificWeight: 1.0,
      ipColocationFactorWeight: 0.0,
      ipColocationFactorThreshold: 1.0,
      behaviourPenaltyWeight: -1.0,
      behaviourPenaltyDecay: 0.999,
    )

proc validateParameters*(parameters: GossipSubParams): Result[void, cstring] =
  if  (parameters.dOut >= GossipSubDlo) or 
      (parameters.dOut > (GossipSubD div 2)):
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
    topicWeight: 1.0,
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
  elif parameters.meshMessageDeliveriesWindow > 100.milliseconds:
    err("gossipsub: meshMessageDeliveriesWindow parameter error, Should be small, 1-5ms")
  elif parameters.meshFailurePenaltyWeight >= 0.0:
    err("gossipsub: meshFailurePenaltyWeight parameter error, Should be a negative value")
  elif parameters.invalidMessageDeliveriesWeight >= 0.0:
    err("gossipsub: invalidMessageDeliveriesWeight parameter error, Should be a negative value")
  else:
    ok()

method init*(g: GossipSub) =
  proc handler(conn: Connection, proto: string) {.async.} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    ## e.g. ``/floodsub/1.0.0``, etc...
    ##

    # TODO
    # if conn.peerInfo.maintain:
    #   g.explicitPeers.incl(conn.peerInfo.id)

    await g.handleConn(conn, proto)

  g.handler = handler
  g.codecs &= GossipSubCodec
  g.codecs &= GossipSubCodec_10

method onNewPeer(g: GossipSub, peer: PubSubPeer) =
  if peer notin g.peerStats:
    # new peer
    g.peerStats[peer] = PeerStats()
    return
  else:
    # we knew this peer
    discard

proc grafted(g: GossipSub, p: PubSubPeer, topic: string) =
  g.peerStats.withValue(p, stats) do:
    var info = stats.topicInfos.getOrDefault(topic)
    info.graftTime = Moment.now()
    info.meshTime = 0.seconds
    info.inMesh = true
    info.meshMessageDeliveriesActive = false

    # mgetOrPut does not work, so we gotta do this without referencing
    stats.topicInfos[topic] = info
    assert(g.peerStats[p].topicInfos[topic].inMesh == true)

    trace "grafted", p
  do:
    doAssert(false, "grafted: peerStats key not found for " & $p)

proc pruned(g: GossipSub, p: PubSubPeer, topic: string) =
  g.peerStats.withValue(p, stats) do:
    when not defined(release):
      g.prunedPeers.incl(p)

    var info = stats.topicInfos[topic]
    let topicParams = g.topicParams.mgetOrPut(topic, TopicParams.init())

    # penalize a peer that delivered no message
    let threshold = topicParams.meshMessageDeliveriesThreshold
    if info.inMesh and info.meshMessageDeliveriesActive and info.meshMessageDeliveries < threshold:
      let deficit = threshold - info.meshMessageDeliveries
      info.meshFailurePenalty += deficit * deficit

    info.inMesh = false

    # mgetOrPut does not work, so we gotta do this without referencing
    stats.topicInfos[topic] = info

    trace "pruned", p
  do:
    when not defined(release):
      if p in g.prunedPeers:
        doAssert(false, "pruned: Dupe prune " & $p)
      else:
        doAssert(false, "pruned: TopicInfo key not found for " & $p)
    else:
      doAssert(false, "pruned: TopicInfo key not found for " & $p)

proc replenishFanout(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  trace "about to replenish fanout"

  if g.fanout.peers(topic) < GossipSubDLo:
    trace "replenishing fanout", peers = g.fanout.peers(topic)
    if topic in g.gossipsub:
      for peer in g.gossipsub[topic]:
        if g.fanout.addPeer(topic, peer):
          if g.fanout.peers(topic) == GossipSubD:
            break

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(topic).int64, labelValues = [topic])

  trace "fanout replenished with peers", peers = g.fanout.peers(topic)

proc rebalanceMesh(g: GossipSub, topic: string) {.async.} =
  logScope:
    topic

  trace "about to rebalance mesh"

  # create a mesh topic that we're subscribing to

  var
    grafts, prunes: seq[PubSubPeer]

  if g.mesh.peers(topic) < GossipSubDlo:
    trace "replenishing mesh", peers = g.mesh.peers(topic)
    # replenish the mesh if we're below Dlo
    grafts = toSeq(
      g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()) -
      g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
    )

    logScope:
      meshPeers = g.mesh.peers(topic)
      grafts = grafts.len

    shuffle(grafts)

    # sort peers by score
    grafts.sort(proc (x, y: PubSubPeer): int =
      let
        peerx = x.score
        peery = y.score
      if peerx < peery: -1
      elif peerx == peery: 0
      else: 1)

    # Graft peers so we reach a count of D
    grafts.setLen(min(grafts.len, GossipSubD - g.mesh.peers(topic)))

    trace "getting peers", topic, peers = grafts.len

    for peer in grafts:
      if g.mesh.addPeer(topic, peer):
        g.grafted(peer, topic)
        g.fanout.removePeer(topic, peer)

  if g.mesh.peers(topic) > GossipSubDhi:
    # prune peers if we've gone over Dhi
    prunes = toSeq(g.mesh[topic])
    shuffle(prunes)
    prunes.setLen(prunes.len - GossipSubD) # .. down to D peers

    trace "about to prune mesh", prunes = prunes.len
    for peer in prunes:
      g.pruned(peer, topic)
      g.mesh.removePeer(topic, peer)

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_fanout
      .set(g.fanout.peers(topic).int64, labelValues = [topic])

    libp2p_gossipsub_peers_per_topic_mesh
      .set(g.mesh.peers(topic).int64, labelValues = [topic])

  # Send changes to peers after table updates to avoid stale state
  let graft = RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))
  let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
  discard await g.broadcast(grafts, graft, DefaultSendTimeout)
  discard await g.broadcast(prunes, prune, DefaultSendTimeout)

  trace "mesh balanced, got peers", peers = g.mesh.peers(topic)

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

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

proc getGossipPeers(g: GossipSub): Table[PubSubPeer, ControlMessage] {.gcsafe.} =
  ## gossip iHave messages to peers
  ##

  trace "getting gossip peers (iHave)"
  let topics = toHashSet(toSeq(g.mesh.keys)) + toHashSet(toSeq(g.fanout.keys))
  let controlMsg = ControlMessage()
  for topic in topics:
    var allPeers = toSeq(g.gossipsub.getOrDefault(topic))
    shuffle(allPeers)

    let mesh = g.mesh.getOrDefault(topic)
    let fanout = g.fanout.getOrDefault(topic)

    let gossipPeers = mesh + fanout
    let mids = g.mcache.window(topic)
    if not mids.len > 0:
      continue

    if topic notin g.gossipsub:
      trace "topic not in gossip array, skipping", topicID = topic
      continue

    let ihave = ControlIHave(topicID: topic, messageIDs: toSeq(mids))
    for peer in allPeers:
      if result.len >= GossipSubD:
        trace "got gossip peers", peers = result.len
        break

      if peer in gossipPeers:
        continue

      if peer notin result:
        result[peer] = controlMsg

      result[peer].ihave.add(ihave)

func `/`(a, b: Duration): float64 =
  let
    fa = float64(a.nanoseconds) / 1000000000
    fb = float64(b.nanoseconds) / 1000000000
  fa / fb

proc updateScores(g: GossipSub) = # avoid async
  trace "updating scores", peers = g.peers.len
  
  let now = Moment.now()
  var evicting: seq[PubSubPeer]

  for peer, stats in g.peerStats.mpairs:
    trace "updating peer score", peer, gossipTopics = peer.topics.len

    if not peer.connected:
      if now > stats.expire:
        evicting.add(peer)
        trace "evicted peer from memory", peer
        continue

    # Per topic
    for topic, topicParams in g.topicParams:
      var info = stats.topicInfos.getOrDefault(topic)

      # Scoring
      var topicScore = 0'f64
      
      if info.inMesh:
        info.meshTime = now - info.graftTime
        if info.meshTime > topicParams.meshMessageDeliveriesActivation:
          info.meshMessageDeliveriesActive = true
        
        # TODO verify this `/` accuracy/correctnes
        var p1 = info.meshTime / topicParams.timeInMeshQuantum
        if p1 > topicParams.timeInMeshCap:
          p1 = topicParams.timeInMeshCap
        trace "p1", peer, p1
        topicScore += p1 * topicParams.timeInMeshWeight
      else:
        info.meshMessageDeliveriesActive = false

      topicScore += info.firstMessageDeliveries * topicParams.firstMessageDeliveriesWeight
      trace "p2", peer, p2 = info.firstMessageDeliveries

      if info.meshMessageDeliveriesActive:
        if info.meshMessageDeliveries < topicParams.meshMessageDeliveriesThreshold:
          let deficit = topicParams.meshMessageDeliveriesThreshold - info.meshMessageDeliveries
          let p3 = deficit * deficit
          trace "p3", peer, p3
          topicScore += p3 * topicParams.meshMessageDeliveriesWeight

      topicScore += info.meshFailurePenalty * topicParams.meshFailurePenaltyWeight
      trace "p3b", peer, p3b = info.meshFailurePenalty

      topicScore += info.invalidMessageDeliveries * info.invalidMessageDeliveries * topicParams.invalidMessageDeliveriesWeight
      trace "p4", p4 = info.invalidMessageDeliveries * info.invalidMessageDeliveries

      trace "updated peer topic's scores", peer, topic, info, topicScore

      peer.score += topicScore * topicParams.topicWeight

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
      
    trace "updated peer's score", peer, score = peer.score
  
  for peer in evicting:
    g.peerStats.del(peer)

proc heartbeat(g: GossipSub) {.async.} =
  while g.heartbeatRunning:
    try:
      trace "running heartbeat", instance = cast[int](g)

      g.updateScores()

      for t in toSeq(g.topics.keys):
        # prune every negative score peer
        # do this before relance
        # in order to avoid grafted -> pruned in the same cycle
        let meshPeers = g.mesh.getOrDefault(t)
        var prunes: seq[PubSubPeer]
        for peer in meshPeers:
          if peer.score < 0.0:
            g.pruned(peer, t)
            g.mesh.removePeer(t, peer)
            prunes &= peer
        let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: t)])))
        discard await g.broadcast(prunes, prune, DefaultSendTimeout)

        await g.rebalanceMesh(t)

      g.dropFanoutPeers()

      # replenish known topics to the fanout
      for t in toSeq(g.fanout.keys):
        g.replenishFanout(t)

      let peers = g.getGossipPeers()
      var sent: seq[Future[void]]
      for peer, control in peers:
        g.peers.withValue(peer.peerId, pubsubPeer) do:
          sent &= g.send(
            pubsubPeer[],
            RPCMsg(control: some(control)),
            DefaultSendTimeout)
      checkFutures(await allFinished(sent))

      g.mcache.shift() # shift the cache
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "exception ocurred in gossipsub heartbeat", exc = exc.msg, trace = exc.getStackTrace()
      assert(false, "exception ocurred in gossipsub heartbeat")

    for trigger in g.heartbeatEvents:
      trace "firing heartbeat event", instance = cast[int](g)
      trigger.fire()

    await sleepAsync(GossipSubHeartbeatInterval)

method unsubscribePeer*(g: GossipSub, peer: PeerID) =
  ## handle peer disconnects
  ##

  trace "unsubscribing gossipsub peer", peer = $peer
  let pubSubPeer = g.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    return

  for t in toSeq(g.gossipsub.keys):
    g.gossipsub.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_gossipsub
        .set(g.gossipsub.peers(t).int64, labelValues = [t])

  for t in toSeq(g.mesh.keys):
    if pubSubPeer in g.mesh[t]:
        g.pruned(pubSubPeer, t)
    g.mesh.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(t).int64, labelValues = [t])

  for t in toSeq(g.fanout.keys):
    g.fanout.removePeer(t, pubSubPeer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(t).int64, labelValues = [t])

    # TODO
    # if peer.peerInfo.maintain:
    #   for t in toSeq(g.explicit.keys):
    #     g.explicit.removePeer(t, peer)
    #   g.explicitPeers.excl(peer.id)
    
    # don't retain bad score peers
    if pubSubPeer.score < 0.0:
      g.peerStats.del(pubSubPeer)
      return

    g.peerStats[pubSubPeer].expire = Moment.now() + g.parameters.retainScore
    for topic, info in g.peerStats[pubSubPeer].topicInfos.mpairs:
      info.firstMessageDeliveries = 0

  procCall FloodSub(g).unsubscribePeer(peer)

method subscribeTopic*(g: GossipSub,
                       topic: string,
                       subscribe: bool,
                       peerId: PeerID) {.gcsafe, async.} =
  await procCall FloodSub(g).subscribeTopic(topic, subscribe, peerId)

  logScope:
    peer = $peerId
    topic

  let peer = g.peers.getOrDefault(peerId)
  if peer == nil:
    # floodsub method logs a trace line already
    return

  g.onNewPeer(peer)

  if subscribe:
    trace "peer subscribed to topic"
    # subscribe remote peer to the topic
    discard g.gossipsub.addPeer(topic, peer)
    if peerId in g.explicitPeers:
      discard g.explicit.addPeer(topic, peer)
  else:
    trace "peer unsubscribed from topic"
    # unsubscribe remote peer from the topic
    g.gossipsub.removePeer(topic, peer)
    g.mesh.removePeer(topic, peer)
    g.fanout.removePeer(topic, peer)
    if peerId in g.explicitPeers:
      g.explicit.removePeer(topic, peer)

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

  when defined(libp2p_expensive_metrics):
    libp2p_gossipsub_peers_per_topic_gossipsub
      .set(g.gossipsub.peers(topic).int64, labelValues = [topic])

  trace "gossip peers", peers = g.gossipsub.peers(topic), topic

  # also rebalance current topic if we are subbed to
  if topic in g.topics:
    await g.rebalanceMesh(topic)

proc handleGraft(g: GossipSub,
                 peer: PubSubPeer,
                 grafts: seq[ControlGraft]): seq[ControlPrune] =
  for graft in grafts:
    let topic = graft.topicID
    logScope:
      peer = peer.id
      topic

    trace "peer grafted topic"

    # TODO
    # # It is an error to GRAFT on a explicit peer
    # if peer.peerInfo.maintain:
    #   trace "attempt to graft an explicit peer",  peer=peer.id, 
    #                                               topicID=graft.topicID
    #   # and such an attempt should be logged and rejected with a PRUNE
    #   result.add(ControlPrune(topicID: graft.topicID))
    #   continue

    # If they send us a graft before they send us a subscribe, what should
    # we do? For now, we add them to mesh but don't add them to gossipsub.
    if peer notin g.peerStats:
      g.peerStats[peer] = PeerStats()
    if topic in g.topics:
      if g.mesh.peers(topic) < GossipSubDHi:
        # In the spec, there's no mention of DHi here, but implicitly, a
        # peer will be removed from the mesh on next rebalance, so we don't want
        # this peer to push someone else out
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
        else:
          trace "peer already in mesh"
      else:
        result.add(ControlPrune(topicID: topic))
    else:
      trace "peer grafting topic we're not interested in"
      result.add(ControlPrune(topicID: topic))

    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(topic).int64, labelValues = [topic])
      libp2p_gossipsub_peers_per_topic_fanout
        .set(g.fanout.peers(topic).int64, labelValues = [topic])

proc handlePrune(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    trace "peer pruned topic", peer = peer.id, topic = prune.topicID

    g.pruned(peer, prune.topicID)
    g.mesh.removePeer(prune.topicID, peer)
    when defined(libp2p_expensive_metrics):
      libp2p_gossipsub_peers_per_topic_mesh
        .set(g.mesh.peers(prune.topicID).int64, labelValues = [prune.topicID])

proc handleIHave(g: GossipSub,
                 peer: PubSubPeer,
                 ihaves: seq[ControlIHave]): ControlIWant =
  for ihave in ihaves:
    trace "peer sent ihave",
      peer = peer.id, topic = ihave.topicID, msgs = ihave.messageIDs

    if ihave.topicID in g.mesh:
      for m in ihave.messageIDs:
        if m notin g.seen:
          result.messageIDs.add(m)

proc handleIWant(g: GossipSub,
                 peer: PubSubPeer,
                 iwants: seq[ControlIWant]): seq[Message] =
  for iwant in iwants:
    for mid in iwant.messageIDs:
      trace "peer sent iwant", peer = peer.id, messageID = mid
      let msg = g.mcache.get(mid)
      if msg.isSome:
        result.add(msg.get())

proc punishPeer(g: GossipSub, peer: PubSubPeer, msg: Message) =
  for t in msg.topicIDs:
    # ensure we init a new topic if unknown
    let _ = g.topicParams.mgetOrPut(t, TopicParams.init())
    # update stats
    var tstats = g.peerStats[peer].topicInfos.getOrDefault(t)
    tstats.invalidMessageDeliveries += 1
    g.peerStats[peer].topicInfos[t] = tstats

method rpcHandler*(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsgs: seq[RPCMsg]) {.async.} =
  await procCall PubSub(g).rpcHandler(peer, rpcMsgs)

  for m in rpcMsgs:                                  # for all RPC messages
    if m.messages.len > 0:                           # if there are any messages
      var toSendPeers: HashSet[PubSubPeer]
      for msg in m.messages:                         # for every message
        let msgId = g.msgIdProvider(msg)
        logScope: msgId

        if msgId in g.seen:
          trace "message already processed, skipping"

          # make sure to update score tho before continuing
          for t in msg.topicIDs:                     # for every topic in the message
            let topicParams = g.topicParams.mgetOrPut(t, TopicParams.init())
                                                    # if in mesh add more delivery score
            var stats = g.peerStats[peer].topicInfos.getOrDefault(t)
            if stats.inMesh:
              stats.meshMessageDeliveries += 1
              if stats.meshMessageDeliveries > topicParams.meshMessageDeliveriesCap:
                stats.meshMessageDeliveries = topicParams.meshMessageDeliveriesCap

                                                    # commit back to the table
            g.peerStats[peer].topicInfos[t] = stats
          continue

        trace "processing message"

        g.seen.put(msgId)                        # add the message to the seen cache

        if g.verifySignature and not msg.verify(peer.peerId):
          trace "dropping message due to failed signature verification"
          g.punishPeer(peer, msg)
          continue

        if not (await g.validate(msg)):
          trace "dropping message due to failed validation", peer
          g.punishPeer(peer, msg)
          continue

        # this shouldn't happen
        if g.peerInfo.peerId == msg.fromPeer:
          trace "skipping messages from self"
          continue

        for t in msg.topicIDs:                     # for every topic in the message
          let topicParams = g.topicParams.mgetOrPut(t, TopicParams.init())

                                                   # contribute to peer score first delivery
          var stats = g.peerStats[peer].topicInfos.getOrDefault(t)
          stats.firstMessageDeliveries += 1
          if stats.firstMessageDeliveries > topicParams.firstMessageDeliveriesCap:
            stats.firstMessageDeliveries = topicParams.firstMessageDeliveriesCap

                                                   # if in mesh add more delivery score
          if stats.inMesh:
            stats.meshMessageDeliveries += 1
            if stats.meshMessageDeliveries > topicParams.meshMessageDeliveriesCap:
              stats.meshMessageDeliveries = topicParams.meshMessageDeliveriesCap

                                                   # commit back to the table
          g.peerStats[peer].topicInfos[t] = stats

          if t in g.floodsub:
            toSendPeers.incl(g.floodsub[t])        # get all floodsub peers for topic

          if t in g.mesh:
            toSendPeers.incl(g.mesh[t])            # get all mesh peers for topic

          if t in g.explicit:
            toSendPeers.incl(g.explicit[t])        # always forward to explicit peers

          if t in g.topics:                        # if we're subscribed to the topic
            for h in g.topics[t].handler:
              trace "calling handler for message", topicId = t,
                                                   localPeer = g.peerInfo.id,
                                                   fromPeer = msg.fromPeer.pretty
              try:
                await h(t, msg.data)               # trigger user provided handler
              except CancelledError as exc:
                raise exc
              except CatchableError as exc:
                trace "exception in message handler", exc = exc.msg

      # forward the message to all peers interested in it
      let published = await g.broadcast(
        toSeq(toSendPeers),
        RPCMsg(messages: m.messages),
        DefaultSendTimeout)

      trace "forwared message to peers", peers = published

    var respControl: ControlMessage
    if m.control.isSome:
      let control = m.control.get()
      g.handlePrune(peer, control.prune)

      respControl.iwant.add(g.handleIHave(peer, control.ihave))
      respControl.prune.add(g.handleGraft(peer, control.graft))
      let messages = g.handleIWant(peer, control.iwant)

      if respControl.graft.len > 0 or respControl.prune.len > 0 or
        respControl.ihave.len > 0:
        try:
          info "sending control message", msg = respControl
          await g.send(
            peer,
            RPCMsg(control: some(respControl), messages: messages),
            DefaultSendTimeout)
        except CancelledError as exc:
          raise exc
        except CatchableError as exc:
          trace "exception forwarding control messages", exc = exc.msg

method subscribe*(g: GossipSub,
                  topic: string,
                  handler: TopicHandler) {.async.} =
  await procCall PubSub(g).subscribe(topic, handler)
  
  # if we have a fanout on this topic break it
  if topic in g.fanout:
    g.fanout.del(topic)
  
  await g.rebalanceMesh(topic)

method unsubscribe*(g: GossipSub,
                    topics: seq[TopicPair]) {.async.} =
  await procCall PubSub(g).unsubscribe(topics)

  for (topic, handler) in topics:
    # delete from mesh only if no handlers are left
    if g.topics[topic].handler.len <= 0:
      if topic in g.mesh:
        let peers = g.mesh.getOrDefault(topic)
        g.mesh.del(topic)
        for peer in peers:
          g.pruned(peer, topic)
        let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
        discard await g.broadcast(toSeq(peers), prune, DefaultSendTimeout)

method unsubscribeAll*(g: GossipSub, topic: string) {.async.} =
  await procCall PubSub(g).unsubscribeAll(topic)

  if topic in g.mesh:
    let peers = g.mesh.getOrDefault(topic)
    g.mesh.del(topic)
    for peer in peers:
      g.pruned(peer, topic)
    let prune = RPCMsg(control: some(ControlMessage(prune: @[ControlPrune(topicID: topic)])))
    discard await g.broadcast(toSeq(peers), prune, DefaultSendTimeout)

method publish*(g: GossipSub,
                topic: string,
                data: seq[byte],
                timeout: Duration = InfiniteDuration): Future[int] {.async.} =
  # base returns always 0
  discard await procCall PubSub(g).publish(topic, data, timeout)
  trace "publishing message on topic", topic, data = data.shortLog

  var peers: HashSet[PubSubPeer]
  if topic.len <= 0: # data could be 0/empty
    return 0

  if g.parameters.floodPublish:
    for id, peer in g.peers:
      if  topic in peer.topics and
          peer.score >= g.parameters.publishThreshold:
        trace "publish: including flood/high score peer", peer = id
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
    g.lastFanoutPubSub[topic] = Moment.fromNow(GossipSubFanoutTTL)

  inc g.msgSeqno
  let
    msg = Message.init(g.peerInfo, data, topic, g.msgSeqno, g.sign)
    msgId = g.msgIdProvider(msg)

  trace "created new message", msg, topic, peers = peers.len

  if msgId notin g.mcache:
    g.mcache.put(msgId, msg)

  let published = await g.broadcast(toSeq(peers), RPCMsg(messages: @[msg]), timeout)
  when defined(libp2p_expensive_metrics):
    if published > 0:
      libp2p_pubsub_messages_published.inc(labelValues = [topic])

  trace "published message to peers", peers = published,
                                      msg = msg.shortLog()
  return published

method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  ## start pubsub
  ## start long running/repeating procedures

  withLock g.heartbeatLock:
    # setup the heartbeat interval
    g.heartbeatRunning = true
    g.heartbeatFut = g.heartbeat()

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"

  ## stop pubsub
  ## stop long running tasks

  withLock g.heartbeatLock:
    # stop heartbeat interval
    g.heartbeatRunning = false
    if not g.heartbeatFut.finished:
      trace "awaiting last heartbeat"
      await g.heartbeatFut

method initPubSub*(g: GossipSub) =
  procCall FloodSub(g).initPubSub()

  g.parameters.validateParameters().tryGet()

  randomize()
  g.mcache = newMCache(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[PubSubPeer]]()     # meshes - topic to peer
  g.fanout = initTable[string, HashSet[PubSubPeer]]()   # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[PubSubPeer]]()# topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Moment]()  # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]()   # pending control messages
  g.heartbeatLock = newAsyncLock()
