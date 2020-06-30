## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, sets
import chronos, chronicles
import pubsubpeer,
       rpc/[message, messages],
       ../protocol,
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo
import metrics

export PubSubPeer
export PubSubObserver

logScope:
  topics = "pubsub"

declareGauge(libp2p_pubsub_peers, "pubsub peer instances")
declareGauge(libp2p_pubsub_topics, "pubsub subscribed topics")
declareCounter(libp2p_pubsub_validation_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_validation_failure, "pubsub failed validated messages")
declarePublicCounter(libp2p_pubsub_messages_published, "published messages", labels = ["topic"])
declareGauge(libp2p_pubsub_peers_per_topic, "pubsub peers per topic", labels = ["topic"])

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
    peerInfo*: PeerInfo               # this peer's info
    topics*: Table[string, Topic]     # local topics
    peers*: Table[string, PubSubPeer] # peerid to peer map
    triggerSelf*: bool                # trigger own local handler on publish
    verifySignature*: bool            # enable signature verification
    sign*: bool                       # enable message signing
    cleanupLock: AsyncLock
    validators*: Table[string, HashSet[ValidatorHandler]]
    observers: ref seq[PubSubObserver] # ref as in smart_ptr
    msgIdProvider*: MsgIdProvider     # Turn message into message id (not nil)

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: seq[string],
               subscribe: bool) {.async.} =
  ## send subscriptions to remote peer
  trace "sending subscriptions", peer = peer.id,
                                 subscribe = subscribe,
                                 topicIDs = topics

  var msg: RPCMsg
  for t in topics:
    trace "sending topic", peer = peer.id,
                           subscribe = subscribe,
                           topicName = t
    msg.subscriptions.add(SubOpts(topic: t, subscribe: subscribe))

  await peer.send(@[msg])

method subscribeTopic*(p: PubSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.base, async.} =
  if subscribe:
    libp2p_pubsub_peers_per_topic.inc(labelValues = [topic])
  else:
    libp2p_pubsub_peers_per_topic.dec(labelValues = [topic])

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
        await p.subscribeTopic(s.topic, s.subscribe, peer.id)

method handleDisconnect*(p: PubSub, peer: PubSubPeer) {.async, base.} =
  ## handle peer disconnects
  if peer.id in p.peers:
    p.peers.del(peer.id)

  # metrics
  libp2p_pubsub_peers.set(p.peers.len.int64)

proc cleanUpHelper(p: PubSub, peer: PubSubPeer) {.async.} =
  try:
    await p.cleanupLock.acquire()
    peer.refs.dec() # decrement refcount
    if peer.refs <= 0:
      await p.handleDisconnect(peer)
  finally:
    p.cleanupLock.release()

proc getPeer(p: PubSub,
             peerInfo: PeerInfo,
             proto: string): PubSubPeer =
  if peerInfo.id in p.peers:
    return p.peers[peerInfo.id]

  # create new pubsub peer
  let peer = newPubSubPeer(peerInfo, proto)
  trace "created new pubsub peer", peerId = peer.id

  # metrics

  p.peers[peer.id] = peer
  peer.refs.inc # increment reference count
  peer.observers = p.observers
  libp2p_pubsub_peers.set(p.peers.len.int64)
  return peer

proc internalCleanup(p: PubSub, conn: Connection) {.async.} =
  # handle connection close
  if isNil(conn):
    return

  var peer = p.getPeer(conn.peerInfo, p.codec)
  await conn.closeEvent.wait()
  trace "pubsub conn closed, cleaning up peer", peer = conn.peerInfo.id
  await p.cleanUpHelper(peer)

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

  try:
    if isNil(conn.peerInfo):
      trace "no valid PeerId for peer"
      await conn.close()
      return

    proc handler(peer: PubSubPeer, msgs: seq[RPCMsg]) {.async.} =
      # call pubsub rpc handler
      await p.rpcHandler(peer, msgs)

    asyncCheck p.internalCleanup(conn)
    let peer = p.getPeer(conn.peerInfo, proto)
    let topics = toSeq(p.topics.keys)
    if topics.len > 0:
      await p.sendSubs(peer, topics, true)

    peer.handler = handler
    await peer.handle(conn) # spawn peer read loop
    trace "pubsub peer handler ended, cleaning up"
  except CancelledError as exc:
    await conn.close()
    raise exc
  except CatchableError as exc:
    trace "exception ocurred in pubsub handle", exc = exc.msg
    await conn.close()

method subscribeToPeer*(p: PubSub,
                        conn: Connection) {.base, async.} =
  if not(isNil(conn)):
    let peer = p.getPeer(conn.peerInfo, p.codec)
    trace "setting connection for peer", peerId = conn.peerInfo.id
    if not peer.connected:
      peer.conn = conn

    asyncCheck p.internalCleanup(conn)

proc connected*(p: PubSub, peer: PeerInfo): bool =
  let peer = p.getPeer(peer, p.codec)
  if not(isNil(peer)):
    return peer.connected

method unsubscribe*(p: PubSub,
                    topics: seq[TopicPair]) {.base, async.} =
  ## unsubscribe from a list of ``topic`` strings
  for t in topics:
    # metrics
    libp2p_pubsub_topics.dec()
    for i, h in p.topics[t.topic].handler:
      if h == t.handler:
        p.topics[t.topic].handler.del(i)

method unsubscribe*(p: PubSub,
                    topic: string,
                    handler: TopicHandler): Future[void] {.base.} =
  ## unsubscribe from a ``topic`` string
  p.unsubscribe(@[(topic, handler)])

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

  for peer in p.peers.values:
    await p.sendSubs(peer, @[topic], true)

  # metrics
  libp2p_pubsub_topics.inc()

method publish*(p: PubSub,
                topic: string,
                data: seq[byte]) {.base, async.} =
  # TODO: Should throw indicating success/failure
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

proc newPubSub*(P: typedesc[PubSub],
                peerInfo: PeerInfo,
                triggerSelf: bool = false,
                verifySignature: bool = true,
                sign: bool = true,
                msgIdProvider: MsgIdProvider = defaultMsgIdProvider): P =
  result = P(peerInfo: peerInfo,
             triggerSelf: triggerSelf,
             verifySignature: verifySignature,
             sign: sign,
             cleanupLock: newAsyncLock(),
             msgIdProvider: msgIdProvider)
  result.initPubSub()

proc addObserver*(p: PubSub; observer: PubSubObserver) =
  p.observers[] &= observer

proc removeObserver*(p: PubSub; observer: PubSubObserver) =
  let idx = p.observers[].find(observer)
  if idx != -1:
    p.observers[].del(idx)
