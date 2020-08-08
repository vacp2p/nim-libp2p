## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sequtils, sets]
import chronos, chronicles, metrics
import pubsubpeer,
       rpc/[message, messages],
       ../../switch,
       ../protocol,
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo,
       ../../errors

export PubSubPeer
export PubSubObserver

logScope:
  topics = "pubsub"

declareGauge(libp2p_pubsub_peers, "pubsub peer instances")
declareGauge(libp2p_pubsub_topics, "pubsub subscribed topics")
declareCounter(libp2p_pubsub_validation_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_validation_failure, "pubsub failed validated messages")
when defined(libp2p_expensive_metrics):
  declarePublicCounter(libp2p_pubsub_messages_published, "published messages", labels = ["topic"])

type
  TopicHandler* = proc(topic: string,
                       data: seq[byte]): Future[void] {.gcsafe.}

  ValidatorHandler* = proc(topic: string,
                           message: Message): Future[bool] {.gcsafe, closure.}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  MsgIdProvider* =
    proc(m: Message): string {.noSideEffect, raises: [Defect], nimcall, gcsafe.}

  Topic* = object
    name*: string
    handler*: seq[TopicHandler]

  PubSub* = ref object of LPProtocol
    switch*: Switch                                 # the switch used to dial/connect to peers
    peerInfo*: PeerInfo                             # this peer's info
    topics*: Table[string, Topic]                   # local topics
    peers*: Table[PeerID, PubSubPeer]               # peerid to peer map
    triggerSelf*: bool                              # trigger own local handler on publish
    verifySignature*: bool                          # enable signature verification
    sign*: bool                                     # enable message signing
    cleanupLock: AsyncLock
    validators*: Table[string, HashSet[ValidatorHandler]]
    observers: ref seq[PubSubObserver]              # ref as in smart_ptr
    msgIdProvider*: MsgIdProvider                   # Turn message into message id (not nil)
    msgSeqno*: uint64
    lifetimeFut*: Future[void]                      # pubsub liftime future

method unsubscribePeer*(p: PubSub, peerId: PeerID) {.base.} =
  ## handle peer disconnects
  ##

  trace "unsubscribing pubsub peer", peer = $peerId
  if peerId in p.peers:
    p.peers.del(peerId)

  libp2p_pubsub_peers.set(p.peers.len.int64)

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: seq[string],
               subscribe: bool) {.async.} =
  ## send subscriptions to remote peer
  await peer.sendSubOpts(topics, subscribe)

method subscribeTopic*(p: PubSub,
                       topic: string,
                       subscribe: bool,
                       peerId: PeerID) {.base, async.} =
  # called when remote peer subscribes to a topic
  discard

method rpcHandler*(p: PubSub,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async, base.} =
  ## handle rpc messages
  trace "processing RPC message", peer = peer.id, msgs = rpcMsgs.len

  for m in rpcMsgs:                                # for all RPC messages
    trace "processing messages", msg = m.shortLog
    if m.subscriptions.len > 0:                    # if there are any subscriptions
      for s in m.subscriptions:                    # subscribe/unsubscribe the peer for each topic
        trace "about to subscribe to topic", topicId = s.topic
        await p.subscribeTopic(s.topic, s.subscribe, peer.peerId)

proc getOrCreatePeer*(
  p: PubSub,
  peer: PeerID,
  proto: string): PubSubPeer =
  if peer in p.peers:
    return p.peers[peer]

  # create new pubsub peer
  let pubSubPeer = newPubSubPeer(peer, p.switch, proto)
  trace "created new pubsub peer", peerId = $peer

  p.peers[peer] = pubSubPeer
  pubSubPeer.observers = p.observers

  libp2p_pubsub_peers.set(p.peers.len.int64)
  return pubSubPeer

method handleConn*(p: PubSub,
                   conn: Connection,
                   proto: string) {.base, async.} =
  ## handle incoming connections
  ##
  ## this proc will:
  ## 1) register a new PubSubPeer for the connection
  ## 2) register a handler with the peer;
  ##    this handler gets called on every rpc message
  ##    that the peer receives
  ## 3) ask the peer to subscribe us to every topic
  ##    that we're interested in
  ##

  if isNil(conn.peerInfo):
    trace "no valid PeerId for peer"
    await conn.close()
    return

  proc handler(peer: PubSubPeer, msgs: seq[RPCMsg]) {.async.} =
    # call pubsub rpc handler
    await p.rpcHandler(peer, msgs)

  let peer = p.getOrCreatePeer(conn.peerInfo.peerId, proto)
  if p.topics.len > 0:
    await p.sendSubs(peer, toSeq(p.topics.keys), true)

  try:
    peer.handler = handler
    await peer.handle(conn) # spawn peer read loop
    trace "pubsub peer handler ended", peer = peer.id
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception ocurred in pubsub handle", exc = exc.msg
  finally:
    await conn.close()

method subscribePeer*(p: PubSub, peer: PeerID) {.base.} =
  ## subscribe to remote peer to receive/send pubsub
  ## messages
  ##

  let pubsubPeer = p.getOrCreatePeer(peer, p.codec)
  if p.topics.len > 0:
    asyncCheck p.sendSubs(pubsubPeer, toSeq(p.topics.keys), true)

  pubsubPeer.subscribed = true

method unsubscribe*(p: PubSub,
                    topics: seq[TopicPair]) {.base, async.} =
  ## unsubscribe from a list of ``topic`` strings
  for t in topics:
    for i, h in p.topics[t.topic].handler:
      if h == t.handler:
        p.topics[t.topic].handler.del(i)

    # make sure we delete the topic if
    # no more handlers are left
    if p.topics[t.topic].handler.len <= 0:
      p.topics.del(t.topic)
      # metrics
      libp2p_pubsub_topics.set(p.topics.len.int64)

proc unsubscribe*(p: PubSub,
                  topic: string,
                  handler: TopicHandler): Future[void] =
  ## unsubscribe from a ``topic`` string
  ##

  p.unsubscribe(@[(topic, handler)])

method unsubscribeAll*(p: PubSub, topic: string) {.base, async.} =
  p.topics.del(topic)
  libp2p_pubsub_topics.set(p.topics.len.int64)

method subscribe*(p: PubSub,
                  topic: string,
                  handler: TopicHandler) {.base, async.} =
  ## subscribe to a topic
  ##
  ## ``topic``   - a string topic to subscribe to
  ##
  ## ``handler`` - is a user provided proc
  ##               that will be triggered
  ##               on every received message
  ##
  if topic notin p.topics:
    trace "subscribing to topic", name = topic
    p.topics[topic] = Topic(name: topic)

  p.topics[topic].handler.add(handler)

  var sent: seq[Future[void]]
  for peer in toSeq(p.peers.values):
    sent.add(p.sendSubs(peer, @[topic], true))

  checkFutures(await allFinished(sent))

  # metrics
  libp2p_pubsub_topics.set(p.topics.len.int64)

proc publishHelper*(p: PubSub,
                    sendPeers: HashSet[PubSubPeer],
                    msgs: seq[Message],
                    timeout: Duration): Future[int] {.async.} =
  # send messages and cleanup failed peers
  var sent: seq[tuple[id: PeerID, fut: Future[void]]]
  for sendPeer in sendPeers:
    if sendPeer.isNil:
      continue

    # avoid sending to self
    if sendPeer.peerId == p.peerInfo.peerId:
      continue

    trace "sending messages to peer", peer = sendPeer.id, msgs
    sent.add((id: sendPeer.peerId, fut: sendPeer.send(RPCMsg(messages: msgs), timeout)))

  var published: seq[PeerID]
  var failed: seq[PeerID]
  let futs = await allFinished(sent.mapIt(it.fut))
  for s in futs:
    let f = sent.filterIt(it.fut == s)
    if f.len > 0:
      if s.failed:
        trace "sending messages to peer failed", peer = f[0].id
        p.unsubscribePeer(f[0].id)
        failed.add(f[0].id)
      else:
        trace "sending messages to peer succeeded", peer = f[0].id
        published.add(f[0].id)

  return published.len

method publish*(p: PubSub,
                topic: string,
                data: seq[byte],
                timeout: Duration = InfiniteDuration): Future[int] {.base, async.} =
  ## publish to a ``topic``
  if p.triggerSelf and topic in p.topics:
    for h in p.topics[topic].handler:
      trace "triggering handler", topicID = topic
      try:
        await h(topic, data)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        # TODO these exceptions are ignored since it's likely that if writes are
        #      are failing, the underlying connection is already closed - this needs
        #      more cleanup though
        debug "Could not write to pubsub connection", msg = exc.msg

  return 0

method initPubSub*(p: PubSub) {.base.} =
  ## perform pubsub initialization
  p.observers = new(seq[PubSubObserver])
  if p.msgIdProvider == nil:
    p.msgIdProvider = defaultMsgIdProvider

method start*(p: PubSub) {.async, base.} =
  ## start pubsub
  discard

method stop*(p: PubSub) {.async, base.} =
  ## stopt pubsub
  discard

method addValidator*(p: PubSub,
                     topic: varargs[string],
                     hook: ValidatorHandler) {.base.} =
  for t in topic:
    if t notin p.validators:
      p.validators[t] = initHashSet[ValidatorHandler]()

    trace "adding validator for topic", topicId = t
    p.validators[t].incl(hook)

method removeValidator*(p: PubSub,
                        topic: varargs[string],
                        hook: ValidatorHandler) {.base.} =
  for t in topic:
    if t in p.validators:
      p.validators[t].excl(hook)

method validate*(p: PubSub, message: Message): Future[bool] {.async, base.} =
  var pending: seq[Future[bool]]
  trace "about to validate message"
  for topic in message.topicIDs:
    trace "looking for validators on topic", topicID = topic,
                                             registered = toSeq(p.validators.keys)
    if topic in p.validators:
      trace "running validators for topic", topicID = topic
      # TODO: add timeout to validator
      pending.add(p.validators[topic].mapIt(it(topic, message)))

  let futs = await allFinished(pending)
  result = futs.allIt(not it.failed and it.read())
  if result:
    libp2p_pubsub_validation_success.inc()
  else:
    libp2p_pubsub_validation_failure.inc()

proc init*(
  P: typedesc[PubSub],
  switch: Switch,
  triggerSelf: bool = false,
  verifySignature: bool = true,
  sign: bool = true,
  msgIdProvider: MsgIdProvider = defaultMsgIdProvider): P =
  result = P(switch: switch,
             peerInfo: switch.peerInfo,
             triggerSelf: triggerSelf,
             verifySignature: verifySignature,
             sign: sign,
             peers: initTable[PeerID, PubSubPeer](),
             topics: initTable[string, Topic](),
             cleanupLock: newAsyncLock(),
             msgIdProvider: msgIdProvider)
  result.initPubSub()

proc addObserver*(p: PubSub; observer: PubSubObserver) =
  p.observers[] &= observer

proc removeObserver*(p: PubSub; observer: PubSubObserver) =
  let idx = p.observers[].find(observer)
  if idx != -1:
    p.observers[].del(idx)
