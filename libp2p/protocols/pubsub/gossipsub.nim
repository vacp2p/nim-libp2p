# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Gossip based publishing

{.push raises: [].}

import std/[sets, sequtils]
import chronos, chronicles, metrics
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

import ./gossipsub/[types, scoring, behavior], ../../utils/heartbeat

export types, scoring, behavior, pubsub

logScope:
  topics = "libp2p gossipsub"

declareCounter(libp2p_gossipsub_failed_publish, "number of failed publish")
declareCounter(libp2p_gossipsub_invalid_topic_subscription, "number of invalid topic subscriptions that happened")
declareCounter(libp2p_gossipsub_duplicate_during_validation, "number of duplicates received during message validation")
declareCounter(libp2p_gossipsub_idontwant_saved_messages, "number of duplicates avoided by idontwant")
declareCounter(libp2p_gossipsub_saved_bytes, "bytes saved by gossipsub optimizations", labels=["kind"])
declareCounter(libp2p_gossipsub_duplicate, "number of duplicates received")
declareCounter(libp2p_gossipsub_received, "number of messages received (deduplicated)")

proc init*(_: type[GossipSubParams]): GossipSubParams =
  GossipSubParams(
      explicit: true,
      pruneBackoff: 1.minutes,
      unsubscribeBackoff: 5.seconds,
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
      gossipThreshold: -100,
      publishThreshold: -1000,
      graylistThreshold: -10000,
      opportunisticGraftThreshold: 0,
      decayInterval: 1.seconds,
      decayToZero: 0.01,
      retainScore: 2.minutes,
      appSpecificWeight: 0.0,
      ipColocationFactorWeight: 0.0,
      ipColocationFactorThreshold: 1.0,
      behaviourPenaltyWeight: -1.0,
      behaviourPenaltyDecay: 0.999,
      disconnectBadPeers: false,
      enablePX: false,
      bandwidthEstimatebps: 100_000_000, # 100 Mbps or 12.5 MBps
      iwantTimeout: 3 * GossipSubHeartbeatInterval
    )

proc validateParameters*(parameters: GossipSubParams): Result[void, cstring] =
  if  (parameters.dOut >= parameters.dLow) or
      (parameters.dOut > (parameters.d div 2)):
    err("gossipsub: dOut parameter error, Number of outbound connections to keep in the mesh. Must be less than D_lo and at most D/2")
  elif parameters.gossipThreshold >= 0:
    err("gossipsub: gossipThreshold parameter error, Must be < 0")
  elif parameters.unsubscribeBackoff.seconds <= 0:
    err("gossipsub: unsubscribeBackoff parameter error, Must be > 0 seconds")
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

method onNewPeer(g: GossipSub, peer: PubSubPeer) =
  g.withPeerStats(peer.peerId) do (stats: var PeerStats):
    # Make sure stats and peer information match, even when reloading peer stats
    # from a previous connection
    peer.score = stats.score
    peer.appScore = stats.appScore
    peer.behaviourPenalty = stats.behaviourPenalty

    # Check if the score is below the threshold and disconnect the peer if necessary
    g.disconnectBadPeerCheck(peer, stats.score)

  peer.iHaveBudget = IHavePeerBudget
  peer.pingBudget = PingsPeerBudget

method onPubSubPeerEvent*(p: GossipSub, peer: PubSubPeer, event: PubSubPeerEvent) {.gcsafe.} =
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

method unsubscribePeer*(g: GossipSub, peer: PeerId) =
  ## handle peer disconnects
  ##

  trace "unsubscribing gossipsub peer", peer
  let pubSubPeer = g.peers.getOrDefault(peer)
  if pubSubPeer.isNil:
    trace "no peer to unsubscribe", peer
    return

  # remove from peer IPs collection too
  pubSubPeer.address.withValue(address):
    g.peersInIP.withValue(address, s):
      s[].excl(pubSubPeer.peerId)
      if s[].len == 0:
        g.peersInIP.del(address)

  for t in toSeq(g.mesh.keys):
    trace "pruning unsubscribing peer", pubSubPeer, score = pubSubPeer.score
    g.pruned(pubSubPeer, t)
    g.mesh.removePeer(t, pubSubPeer)

  for t in toSeq(g.gossipsub.keys):
    g.gossipsub.removePeer(t, pubSubPeer)
    # also try to remove from explicit table here
    g.explicit.removePeer(t, pubSubPeer)

  for t in toSeq(g.fanout.keys):
    g.fanout.removePeer(t, pubSubPeer)

  g.peerStats.withValue(peer, stats):
    for topic, info in stats[].topicInfos.mpairs:
      info.firstMessageDeliveries = 0

  procCall FloodSub(g).unsubscribePeer(peer)

proc handleSubscribe*(g: GossipSub,
                      peer: PubSubPeer,
                      topic: string,
                      subscribe: bool) =
  logScope:
    peer
    topic

  if subscribe:
    # this is a workaround for a race condition
    # that can happen if we disconnect the peer very early
    # in the future we might use this as a test case
    # and eventually remove this workaround
    if peer.peerId notin g.peers:
      trace "ignoring unknown peer"
      return

    if not(isNil(g.subscriptionValidator)) and not(g.subscriptionValidator(topic)):
      # this is a violation, so warn should be in order
      trace "ignoring invalid topic subscription", topic, peer
      libp2p_gossipsub_invalid_topic_subscription.inc()
      return

    trace "peer subscribed to topic"

    # subscribe remote peer to the topic
    discard g.gossipsub.addPeer(topic, peer)
    if peer.peerId in g.parameters.directPeers:
      discard g.explicit.addPeer(topic, peer)
  else:
    trace "peer unsubscribed from topic"

    if g.mesh.hasPeer(topic, peer):
      #against spec
      g.mesh.removePeer(topic, peer)
      g.pruned(peer, topic)

    # unsubscribe remote peer from the topic
    g.gossipsub.removePeer(topic, peer)

    g.fanout.removePeer(topic, peer)
    if peer.peerId in g.parameters.directPeers:
      g.explicit.removePeer(topic, peer)

  trace "gossip peers", peers = g.gossipsub.peers(topic), topic

proc handleControl(g: GossipSub, peer: PubSubPeer, control: ControlMessage) =
  g.handlePrune(peer, control.prune)

  var respControl: ControlMessage
  g.handleIDontWant(peer, control.idontwant)
  let iwant = g.handleIHave(peer, control.ihave)
  if iwant.messageIds.len > 0:
    respControl.iwant.add(iwant)
  respControl.prune.add(g.handleGraft(peer, control.graft))
  let messages = g.handleIWant(peer, control.iwant)

  if
    respControl.prune.len > 0 or
    respControl.iwant.len > 0 or
    messages.len > 0:
    # iwant and prunes from here, also messages

    for smsg in messages:
      for topic in smsg.topicIds:
        if g.knownTopics.contains(topic):
          libp2p_pubsub_broadcast_messages.inc(labelValues = [topic])
        else:
          libp2p_pubsub_broadcast_messages.inc(labelValues = ["generic"])

    libp2p_pubsub_broadcast_iwant.inc(respControl.iwant.len.int64)

    for prune in respControl.prune:
      if g.knownTopics.contains(prune.topicId):
        libp2p_pubsub_broadcast_prune.inc(labelValues = [prune.topicId])
      else:
        libp2p_pubsub_broadcast_prune.inc(labelValues = ["generic"])

    trace "sending control message", msg = shortLog(respControl), peer
    g.send(
      peer,
      RPCMsg(control: some(respControl), messages: messages))

proc validateAndRelay(g: GossipSub,
                      msg: Message,
                      msgId, msgIdSalted: MessageId,
                      peer: PubSubPeer) {.async.} =
  try:
    let validation = await g.validate(msg)

    var seenPeers: HashSet[PubSubPeer]
    discard g.validationSeen.pop(msgIdSalted, seenPeers)
    libp2p_gossipsub_duplicate_during_validation.inc(seenPeers.len.int64)
    libp2p_gossipsub_saved_bytes.inc((msg.data.len * seenPeers.len).int64, labelValues = ["validation_duplicate"])

    case validation
    of ValidationResult.Reject:
      debug "Dropping message after validation, reason: reject",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIds)
      return
    of ValidationResult.Ignore:
      debug "Dropping message after validation, reason: ignore",
        msgId = shortLog(msgId), peer
      return
    of ValidationResult.Accept:
      discard

    # store in cache only after validation
    g.mcache.put(msgId, msg)

    g.rewardDelivered(peer, msg.topicIds, true)

    var toSendPeers = HashSet[PubSubPeer]()
    for t in msg.topicIds:                      # for every topic in the message
      if t notin g.topics:
        continue

      g.floodsub.withValue(t, peers): toSendPeers.incl(peers[])
      g.mesh.withValue(t, peers): toSendPeers.incl(peers[])

    # Don't send it to source peer, or peers that
    # sent it during validation
    toSendPeers.excl(peer)
    toSendPeers.excl(seenPeers)

    # IDontWant is only worth it if the message is substantially
    # bigger than the messageId
    if msg.data.len > msgId.len * 10:
      g.broadcast(toSendPeers, RPCMsg(control: some(ControlMessage(
          idontwant: @[ControlIWant(messageIds: @[msgId])]
        ))))

    for peer in toSendPeers:
      for heDontWant in peer.heDontWants:
        if msgId in heDontWant:
          seenPeers.incl(peer)
          libp2p_gossipsub_idontwant_saved_messages.inc
          libp2p_gossipsub_saved_bytes.inc(msg.data.len.int64, labelValues = ["idontwant"])
          break
    toSendPeers.excl(seenPeers)


    # In theory, if topics are the same in all messages, we could batch - we'd
    # also have to be careful to only include validated messages
    g.broadcast(toSendPeers, RPCMsg(messages: @[msg]))
    trace "forwarded message to peers", peers = toSendPeers.len, msgId, peer
    for topic in msg.topicIds:
      if topic notin g.topics: continue

      if g.knownTopics.contains(topic):
        libp2p_pubsub_messages_rebroadcasted.inc(toSendPeers.len.int64, labelValues = [topic])
      else:
        libp2p_pubsub_messages_rebroadcasted.inc(toSendPeers.len.int64, labelValues = ["generic"])

      await handleData(g, topic, msg.data)
  except CatchableError as exc:
    info "validateAndRelay failed", msg=exc.msg

method rpcHandler*(g: GossipSub,
                  peer: PubSubPeer,
                  rpcMsg: RPCMsg) {.async.} =
  if rpcMsg.ping.len in 1..<64 and peer.pingBudget > 0:
    g.send(peer, RPCMsg(pong: rpcMsg.ping))
    peer.pingBudget.dec
  for i in 0..<min(g.topicsHigh, rpcMsg.subscriptions.len):
    template sub: untyped = rpcMsg.subscriptions[i]
    g.handleSubscribe(peer, sub.topic, sub.subscribe)

  # the above call applied limits to subs number
  # in gossipsub we want to apply scoring as well
  if rpcMsg.subscriptions.len > g.topicsHigh:
    debug "received an rpc message with an oversized amount of subscriptions",  peer,
                                                                                size = rpcMsg.subscriptions.len,
                                                                                limit = g.topicsHigh
    peer.behaviourPenalty += 0.1

  for i in 0..<rpcMsg.messages.len():                         # for every message
    template msg: untyped = rpcMsg.messages[i]
    let msgIdResult = g.msgIdProvider(msg)

    if msgIdResult.isErr:
      debug "Dropping message due to failed message id generation",
        error = msgIdResult.error
      # TODO: descore peers due to error during message validation (malicious?)
      continue

    let
      msgId = msgIdResult.get
      msgIdSalted = msgId & g.seenSalt
    g.outstandingIWANTs.withValue(msgId, iwantRequest):
      if iwantRequest.peer.peerId == peer.peerId:
        g.outstandingIWANTs.del(msgId)

    # addSeen adds salt to msgId to avoid
    # remote attacking the hash function
    if g.addSeen(msgId):
      trace "Dropping already-seen message", msgId = shortLog(msgId), peer

      var alreadyReceived = false
      g.validationSeen.withValue(msgIdSalted, seen):
        if seen[].containsOrIncl(peer):
          # peer sent us this message twice
          alreadyReceived = true

      if not alreadyReceived:
        let delay = Moment.now() - g.firstSeen(msgId)
        g.rewardDelivered(peer, msg.topicIds, false, delay)

      libp2p_gossipsub_duplicate.inc()

      # onto the next message
      continue

    libp2p_gossipsub_received.inc()

    # avoid processing messages we are not interested in
    if msg.topicIds.allIt(it notin g.topics):
      debug "Dropping message of topic without subscription", msgId = shortLog(msgId), peer
      continue

    if (msg.signature.len > 0 or g.verifySignature) and not msg.verify():
      # always validate if signature is present or required
      debug "Dropping message due to failed signature verification",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIds)
      continue

    if msg.seqno.len > 0 and msg.seqno.len != 8:
      # if we have seqno should be 8 bytes long
      debug "Dropping message due to invalid seqno length",
        msgId = shortLog(msgId), peer
      g.punishInvalidMessage(peer, msg.topicIds)
      continue

    # g.anonymize needs no evaluation when receiving messages
    # as we have a "lax" policy and allow signed messages

    # Be careful not to fill the validationSeen table
    # (eg, pop everything you put in it)
    g.validationSeen[msgIdSalted] = initHashSet[PubSubPeer]()

    asyncSpawn g.validateAndRelay(msg, msgId, msgIdSalted, peer)

  if rpcMsg.control.isSome():
    g.handleControl(peer, rpcMsg.control.unsafeGet())

  # Now, check subscription to update the meshes if required
  for i in 0..<min(g.topicsHigh, rpcMsg.subscriptions.len):
    let topic = rpcMsg.subscriptions[i].topic
    if topic in g.topics and g.mesh.peers(topic) < g.parameters.dLow:
      # rebalance but don't update metrics here, we do that only in the heartbeat
      g.rebalanceMesh(topic, metrics = nil)

  g.updateMetrics(rpcMsg)

method onTopicSubscription*(g: GossipSub, topic: string, subscribed: bool) =
  if subscribed:
    procCall PubSub(g).onTopicSubscription(topic, subscribed)

    # if we have a fanout on this topic break it
    if topic in g.fanout:
      g.fanout.del(topic)

    # rebalance but don't update metrics here, we do that only in the heartbeat
    g.rebalanceMesh(topic, metrics = nil)
  else:
    let mpeers = g.mesh.getOrDefault(topic)

    # Remove peers from the mesh since we're no longer both interested
    # in the topic
    let msg = RPCMsg(control: some(ControlMessage(
          prune: @[ControlPrune(
            topicID: topic,
            peers: g.peerExchangeList(topic),
            backoff: g.parameters.unsubscribeBackoff.seconds.uint64)])))
    g.broadcast(mpeers, msg)

    for peer in mpeers:
      g.pruned(peer, topic, backoff = some(g.parameters.unsubscribeBackoff))

    g.mesh.del(topic)


    # Send unsubscribe (in reverse order to sub/graft)
    procCall PubSub(g).onTopicSubscription(topic, subscribed)

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

  # add always direct peers
  peers.incl(g.explicit.getOrDefault(topic))

  if topic in g.topics: # if we're subscribed use the mesh
    peers.incl(g.mesh.getOrDefault(topic))

  if g.parameters.floodPublish:
    # With flood publishing enabled, the mesh is used when propagating messages from other peers,
    # but a peer's own messages will always be published to all known peers in the topic, limited
    # to the amount of peers we can send it to in one heartbeat
    var maxPeersToFlodOpt: Opt[int64]
    if g.parameters.bandwidthEstimatebps > 0:
      let
        bandwidth = (g.parameters.bandwidthEstimatebps) div 8 div 1000 # Divisions are to convert it to Bytes per ms TODO replace with bandwidth estimate
        msToTransmit = max(data.len div bandwidth, 1)
      maxPeersToFlodOpt = Opt.some(max(g.parameters.heartbeatInterval.milliseconds div msToTransmit, g.parameters.dLow))

    for peer in g.gossipsub.getOrDefault(topic):
      maxPeersToFlodOpt.withValue(maxPeersToFlod):
        if peers.len >= maxPeersToFlod: break
      if peer.score >= g.parameters.publishThreshold:
        trace "publish: including flood/high score peer", peer
        peers.incl(peer)

  if peers.len < g.parameters.dLow:
    # not subscribed, or bad mesh, send to fanout peers
    var fanoutPeers = g.fanout.getOrDefault(topic).toSeq()
    if fanoutPeers.len < g.parameters.dLow:
      g.replenishFanout(topic)
      fanoutPeers = g.fanout.getOrDefault(topic).toSeq()

    g.rng.shuffle(fanoutPeers)

    for fanPeer in fanoutPeers:
      peers.incl(fanPeer)
      if peers.len > g.parameters.d: break

    # even if we couldn't publish,
    # we still attempted to publish
    # on the topic, so it makes sense
    # to update the last topic publish
    # time
    g.lastFanoutPubSub[topic] = Moment.fromNow(g.parameters.fanoutTTL)

  if peers.len == 0:
    let topicPeers = g.gossipsub.getOrDefault(topic).toSeq()
    debug "No peers for topic, skipping publish",  peersOnTopic = topicPeers.len,
                                                   connectedPeers = topicPeers.filterIt(it.connected).len,
                                                   topic
    libp2p_gossipsub_failed_publish.inc()
    return 0

  let
    msg =
      if g.anonymize:
        Message.init(none(PeerInfo), data, topic, none(uint64), false)
      else:
        inc g.msgSeqno
        Message.init(some(g.peerInfo), data, topic, some(g.msgSeqno), g.sign)
    msgId = g.msgIdProvider(msg).valueOr:
      trace "Error generating message id, skipping publish",
        error = error
      libp2p_gossipsub_failed_publish.inc()
      return 0

  logScope: msgId = shortLog(msgId)

  trace "Created new message", msg = shortLog(msg), peers = peers.len

  if g.addSeen(msgId):
    # custom msgid providers might cause this
    trace "Dropping already-seen message"
    return 0

  g.mcache.put(msgId, msg)

  g.broadcast(peers, RPCMsg(messages: @[msg]))

  if g.knownTopics.contains(topic):
    libp2p_pubsub_messages_published.inc(peers.len.int64, labelValues = [topic])
  else:
    libp2p_pubsub_messages_published.inc(peers.len.int64, labelValues = ["generic"])

  trace "Published message to peers", peers=peers.len
  return peers.len

proc maintainDirectPeer(g: GossipSub, id: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let peer = g.peers.getOrDefault(id)
  if isNil(peer):
    trace "Attempting to dial a direct peer", peer = id
    try:
      await g.switch.connect(id, addrs)
      # populate the peer after it's connected
      discard g.getOrCreatePeer(id, g.codecs)
    except CancelledError as exc:
      trace "Direct peer dial canceled"
      raise exc
    except CatchableError as exc:
      debug "Direct peer error dialing", msg = exc.msg

proc addDirectPeer*(g: GossipSub, id: PeerId, addrs: seq[MultiAddress]) {.async.} =
  g.parameters.directPeers[id] = addrs
  await g.maintainDirectPeer(id, addrs)

proc maintainDirectPeers(g: GossipSub) {.async.} =
  heartbeat "GossipSub DirectPeers", 1.minutes:
    for id, addrs in g.parameters.directPeers:
      await g.addDirectPeer(id, addrs)

method start*(g: GossipSub) {.async.} =
  trace "gossipsub start"

  if not g.heartbeatFut.isNil:
    warn "Starting gossipsub twice"
    return

  g.heartbeatFut = g.heartbeat()
  g.scoringHeartbeatFut = g.scoringHeartbeat()
  g.directPeersLoop = g.maintainDirectPeers()
  g.started = true

method stop*(g: GossipSub) {.async.} =
  trace "gossipsub stop"
  g.started = false
  if g.heartbeatFut.isNil:
    warn "Stopping gossipsub without starting it"
    return

  # stop heartbeat interval
  g.directPeersLoop.cancel()
  g.scoringHeartbeatFut.cancel()
  g.heartbeatFut.cancel()
  g.heartbeatFut = nil

method initPubSub*(g: GossipSub)
  {.raises: [InitializationError].} =
  procCall FloodSub(g).initPubSub()

  if not g.parameters.explicit:
    g.parameters = GossipSubParams.init()

  let validationRes = g.parameters.validateParameters()
  if validationRes.isErr:
    raise newException(InitializationError, $validationRes.error)

  # init the floodsub stuff here, we customize timedcache in gossip!
  g.seen = TimedCache[MessageId].init(g.parameters.seenTTL)

  # init gossip stuff
  g.mcache = MCache.init(g.parameters.historyGossip, g.parameters.historyLength)
