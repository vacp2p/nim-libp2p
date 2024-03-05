# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Base interface for pubsub protocols
##
## You can `subscribe<#subscribe%2CPubSub%2Cstring%2CTopicHandler>`_ to a topic,
## `publish<#publish.e%2CPubSub%2Cstring%2Cseq%5Bbyte%5D>`_ something on it,
## and eventually `unsubscribe<#unsubscribe%2CPubSub%2Cstring%2CTopicHandler>`_ from it.

{.push raises: [].}

import std/[tables, sequtils, sets, strutils]
import chronos, chronicles, metrics
import chronos/ratelimit
import ./errors as pubsub_errors,
       ./pubsubpeer,
       ./rpc/[message, messages, protobuf],
       ../../switch,
       ../protocol,
       ../../crypto/crypto,
       ../../stream/connection,
       ../../peerid,
       ../../peerinfo,
       ../../errors,
       ../../utility

import metrics
import stew/results
export results

export tables, sets
export PubSubPeer
export PubSubObserver
export protocol
export pubsub_errors

logScope:
  topics = "libp2p pubsub"

const
  KnownLibP2PTopics* {.strdefine.} = ""
  KnownLibP2PTopicsSeq* = KnownLibP2PTopics.toLowerAscii().split(",")

declareGauge(libp2p_pubsub_peers, "pubsub peer instances")
declareGauge(libp2p_pubsub_topics, "pubsub subscribed topics")
declareCounter(libp2p_pubsub_subscriptions, "pubsub subscription operations")
declareCounter(libp2p_pubsub_unsubscriptions, "pubsub unsubscription operations")
declareGauge(libp2p_pubsub_topic_handlers, "pubsub subscribed topics handlers count", labels = ["topic"])

declareCounter(libp2p_pubsub_validation_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_validation_failure, "pubsub failed validated messages")
declareCounter(libp2p_pubsub_validation_ignore, "pubsub ignore validated messages")

declarePublicCounter(libp2p_pubsub_messages_published, "published messages", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_messages_rebroadcasted, "re-broadcasted messages", labels = ["topic"])

declarePublicCounter(libp2p_pubsub_broadcast_subscriptions, "pubsub broadcast subscriptions", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_broadcast_unsubscriptions, "pubsub broadcast unsubscriptions", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_broadcast_messages, "pubsub broadcast messages", labels = ["topic"])

declarePublicCounter(libp2p_pubsub_received_subscriptions, "pubsub received subscriptions", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_received_unsubscriptions, "pubsub received subscriptions", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_received_messages, "pubsub received messages", labels = ["topic"])

declarePublicCounter(libp2p_pubsub_broadcast_iwant, "pubsub broadcast iwant")

declarePublicCounter(libp2p_pubsub_broadcast_ihave, "pubsub broadcast ihave", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_broadcast_graft, "pubsub broadcast graft", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_broadcast_prune, "pubsub broadcast prune", labels = ["topic"])

declarePublicCounter(libp2p_pubsub_received_iwant, "pubsub broadcast iwant")

declarePublicCounter(libp2p_pubsub_received_ihave, "pubsub broadcast ihave", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_received_graft, "pubsub broadcast graft", labels = ["topic"])
declarePublicCounter(libp2p_pubsub_received_prune, "pubsub broadcast prune", labels = ["topic"])

type
  InitializationError* = object of LPError

  TopicHandler* {.public.} = proc(topic: string,
                       data: seq[byte]): Future[void] {.gcsafe, raises: [].}

  ValidatorHandler* {.public.} = proc(topic: string,
                           message: Message): Future[ValidationResult] {.gcsafe, raises: [].}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  MsgIdProvider* {.public.} =
    proc(m: Message): Result[MessageId, ValidationResult] {.noSideEffect, raises: [], gcsafe.}

  SubscriptionValidator* {.public.} =
    proc(topic: string): bool {.raises: [], gcsafe.}
    ## Every time a peer send us a subscription (even to an unknown topic),
    ## we have to store it, which may be an attack vector.
    ## This callback can be used to reject topic we're not interested in

  PubSub* {.public.} = ref object of LPProtocol
    switch*: Switch                    # the switch used to dial/connect to peers
    peerInfo*: PeerInfo                # this peer's info
    topics*: Table[string, seq[TopicHandler]]      # the topics that _we_ are interested in
    peers*: Table[PeerId, PubSubPeer]  #\
      # Peers that we are interested to gossip with (but not necessarily
      # yet connected to)
    triggerSelf*: bool                 ## trigger own local handler on publish
    verifySignature*: bool             ## enable signature verification
    sign*: bool                        ## enable message signing
    validators*: Table[string, HashSet[ValidatorHandler]]
    observers: ref seq[PubSubObserver] # ref as in smart_ptr
    msgIdProvider*: MsgIdProvider      ## Turn message into message id (not nil)
    msgSeqno*: uint64
    anonymize*: bool                   ## if we omit fromPeer and seqno from RPC messages we send
    subscriptionValidator*: SubscriptionValidator # callback used to validate subscriptions
    topicsHigh*: int                  ## the maximum number of topics a peer is allowed to subscribe to
    maxMessageSize*: int          ##\
      ## the maximum raw message size we'll globally allow
      ## for finer tuning, check message size on topic validator
      ##
      ## sending a big message to a peer with a lower size limit can
      ## lead to issues, from descoring to connection drops
      ##
      ## defaults to 1mB
    rng*: ref HmacDrbgContext

    knownTopics*: HashSet[string]

method unsubscribePeer*(p: PubSub, peerId: PeerId) {.base, gcsafe.} =
  ## handle peer disconnects
  ##

  debug "unsubscribing pubsub peer", peerId
  p.peers.del(peerId)

  libp2p_pubsub_peers.set(p.peers.len.int64)

proc send*(p: PubSub, peer: PubSubPeer, msg: RPCMsg, isHighPriority: bool) {.raises: [].} =
  ## This procedure attempts to send a `msg` (of type `RPCMsg`) to the specified remote peer in the PubSub network.
  ##
  ## Parameters:
  ## - `p`: The `PubSub` instance.
  ## - `peer`: An instance of `PubSubPeer` representing the peer to whom the message should be sent.
  ## - `msg`: The `RPCMsg` instance that contains the message to be sent.
  ## - `isHighPriority`: A boolean indicating whether the message should be treated as high priority.
  ## High priority messages are sent immediately, while low priority messages are queued and sent only after all high
  ## priority messages have been sent.

  trace "sending pubsub message to peer", peer, msg = shortLog(msg)
  peer.send(msg, p.anonymize, isHighPriority)

proc broadcast*(
  p: PubSub,
  sendPeers: auto, # Iteratble[PubSubPeer]
  msg: RPCMsg,
  isHighPriority: bool) {.raises: [].} =
  ## This procedure attempts to send a `msg` (of type `RPCMsg`) to a specified group of peers in the PubSub network.
  ##
  ## Parameters:
  ## - `p`: The `PubSub` instance.
  ## - `sendPeers`: An iterable of `PubSubPeer` instances representing the peers to whom the message should be sent.
  ## - `msg`: The `RPCMsg` instance that contains the message to be broadcast.
  ## - `isHighPriority`: A boolean indicating whether the message should be treated as high priority.
  ## High priority messages are sent immediately, while low priority messages are queued and sent only after all high
  ## priority messages have been sent.

  let npeers = sendPeers.len.int64
  for sub in msg.subscriptions:
    if sub.subscribe:
      if p.knownTopics.contains(sub.topic):
        libp2p_pubsub_broadcast_subscriptions.inc(npeers, labelValues = [sub.topic])
      else:
        libp2p_pubsub_broadcast_subscriptions.inc(npeers, labelValues = ["generic"])
    else:
      if p.knownTopics.contains(sub.topic):
        libp2p_pubsub_broadcast_unsubscriptions.inc(npeers, labelValues = [sub.topic])
      else:
        libp2p_pubsub_broadcast_unsubscriptions.inc(npeers, labelValues = ["generic"])

  for smsg in msg.messages:
    let topic = smsg.topicId
    if p.knownTopics.contains(topic):
      libp2p_pubsub_broadcast_messages.inc(npeers, labelValues = [topic])
    else:
      libp2p_pubsub_broadcast_messages.inc(npeers, labelValues = ["generic"])

  msg.control.withValue(control):
    libp2p_pubsub_broadcast_iwant.inc(npeers * control.iwant.len.int64)

    for ihave in control.ihave:
      if p.knownTopics.contains(ihave.topicId):
        libp2p_pubsub_broadcast_ihave.inc(npeers, labelValues = [ihave.topicId])
      else:
        libp2p_pubsub_broadcast_ihave.inc(npeers, labelValues = ["generic"])
    for graft in control.graft:
      if p.knownTopics.contains(graft.topicId):
        libp2p_pubsub_broadcast_graft.inc(npeers, labelValues = [graft.topicId])
      else:
        libp2p_pubsub_broadcast_graft.inc(npeers, labelValues = ["generic"])
    for prune in control.prune:
      if p.knownTopics.contains(prune.topicId):
        libp2p_pubsub_broadcast_prune.inc(npeers, labelValues = [prune.topicId])
      else:
        libp2p_pubsub_broadcast_prune.inc(npeers, labelValues = ["generic"])

  trace "broadcasting messages to peers",
    peers = sendPeers.len, msg = shortLog(msg)

  if anyIt(sendPeers, it.hasObservers):
    for peer in sendPeers:
      p.send(peer, msg, isHighPriority)
  else:
    # Fast path that only encodes message once
    let encoded = encodeRpcMsg(msg, p.anonymize)
    for peer in sendPeers:
      asyncSpawn peer.sendEncoded(encoded, isHighPriority)

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: openArray[string],
               subscribe: bool) =
  ## send subscriptions to remote peer
  p.send(peer, RPCMsg.withSubs(topics, subscribe), isHighPriority = true)

  for topic in topics:
    if subscribe:
      if p.knownTopics.contains(topic):
        libp2p_pubsub_broadcast_subscriptions.inc(labelValues = [topic])
      else:
        libp2p_pubsub_broadcast_subscriptions.inc(labelValues = ["generic"])
    else:
      if p.knownTopics.contains(topic):
        libp2p_pubsub_broadcast_unsubscriptions.inc(labelValues = [topic])
      else:
        libp2p_pubsub_broadcast_unsubscriptions.inc(labelValues = ["generic"])

proc updateMetrics*(p: PubSub, rpcMsg: RPCMsg) =
  for i in 0..<min(rpcMsg.subscriptions.len, p.topicsHigh):
    template sub(): untyped = rpcMsg.subscriptions[i]
    if sub.subscribe:
      if p.knownTopics.contains(sub.topic):
        libp2p_pubsub_received_subscriptions.inc(labelValues = [sub.topic])
      else:
        libp2p_pubsub_received_subscriptions.inc(labelValues = ["generic"])
    else:
      if p.knownTopics.contains(sub.topic):
        libp2p_pubsub_received_unsubscriptions.inc(labelValues = [sub.topic])
      else:
        libp2p_pubsub_received_unsubscriptions.inc(labelValues = ["generic"])

  for i in 0..<rpcMsg.messages.len():
    let topic = rpcMsg.messages[i].topicId
    if p.knownTopics.contains(topic):
      libp2p_pubsub_received_messages.inc(labelValues = [topic])
    else:
      libp2p_pubsub_received_messages.inc(labelValues = ["generic"])

  rpcMsg.control.withValue(control):
    libp2p_pubsub_received_iwant.inc(control.iwant.len.int64)
    for ihave in control.ihave:
      if p.knownTopics.contains(ihave.topicId):
        libp2p_pubsub_received_ihave.inc(labelValues = [ihave.topicId])
      else:
        libp2p_pubsub_received_ihave.inc(labelValues = ["generic"])
    for graft in control.graft:
      if p.knownTopics.contains(graft.topicId):
        libp2p_pubsub_received_graft.inc(labelValues = [graft.topicId])
      else:
        libp2p_pubsub_received_graft.inc(labelValues = ["generic"])
    for prune in control.prune:
      if p.knownTopics.contains(prune.topicId):
        libp2p_pubsub_received_prune.inc(labelValues = [prune.topicId])
      else:
        libp2p_pubsub_received_prune.inc(labelValues = ["generic"])

method rpcHandler*(p: PubSub,
                   peer: PubSubPeer,
                   data: seq[byte]): Future[void] {.base, async.} =
  ## Handler that must be overridden by concrete implementation
  raiseAssert "Unimplemented"

method onNewPeer(p: PubSub, peer: PubSubPeer) {.base, gcsafe.} = discard

method onPubSubPeerEvent*(p: PubSub, peer: PubSubPeer, event: PubSubPeerEvent) {.base, gcsafe.} =
  # Peer event is raised for the send connection in particular
  case event.kind
  of PubSubPeerEventKind.Connected:
    if p.topics.len > 0:
      p.sendSubs(peer, toSeq(p.topics.keys), true)
  of PubSubPeerEventKind.Disconnected:
    discard

method getOrCreatePeer*(
    p: PubSub,
    peerId: PeerId,
    protos: seq[string]): PubSubPeer {.base, gcsafe.} =

  p.peers.withValue(peerId, peer):
    return peer[]

  proc getConn(): Future[Connection] {.async.} =
    return await p.switch.dial(peerId, protos)

  proc onEvent(peer: PubSubPeer, event: PubSubPeerEvent) {.gcsafe.} =
    p.onPubSubPeerEvent(peer, event)

  # create new pubsub peer
  let pubSubPeer = PubSubPeer.new(peerId, getConn, onEvent, protos[0], p.maxMessageSize)
  debug "created new pubsub peer", peerId

  p.peers[peerId] = pubSubPeer
  pubSubPeer.observers = p.observers

  onNewPeer(p, pubSubPeer)

  # metrics
  libp2p_pubsub_peers.set(p.peers.len.int64)

  return pubSubPeer

proc handleData*(p: PubSub, topic: string, data: seq[byte]): Future[void] =
  # Start work on all data handlers without copying data into closure like
  # happens on {.async.} transformation
  p.topics.withValue(topic, handlers) do:
    var futs = newSeq[Future[void]]()

    for handler in handlers[]:
      if handler != nil: # allow nil handlers
        let fut = handler(topic, data)
        if not fut.completed(): # Fast path for successful sync handlers
          futs.add(fut)

    if futs.len() > 0:
      proc waiter(): Future[void] {.async.} =
        # slow path - we have to wait for the handlers to complete
        try:
          futs = await allFinished(futs)
        except CancelledError:
          # propagate cancellation
          for fut in futs:
            if not(fut.finished):
              fut.cancel()

        # check for errors in futures
        for fut in futs:
          if fut.failed:
            let err = fut.readError()
            warn "Error in topic handler", msg = err.msg
      return waiter()

  # Fast path - futures finished synchronously or nobody cared about data
  var res = newFuture[void]()
  res.complete()
  return res

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

  proc handler(peer: PubSubPeer, data: seq[byte]): Future[void] =
    # call pubsub rpc handler
    p.rpcHandler(peer, data)

  let peer = p.getOrCreatePeer(conn.peerId, @[proto])

  try:
    peer.handler = handler
    await peer.handle(conn) # spawn peer read loop
    trace "pubsub peer handler ended", conn
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception ocurred in pubsub handle", exc = exc.msg, conn
  finally:
    await conn.closeWithEOF()

method subscribePeer*(p: PubSub, peer: PeerId) {.base, gcsafe.} =
  ## subscribe to remote peer to receive/send pubsub
  ## messages
  ##

  let pubSubPeer = p.getOrCreatePeer(peer, p.codecs)
  pubSubPeer.connect()

proc updateTopicMetrics(p: PubSub, topic: string) =
  # metrics
  libp2p_pubsub_topics.set(p.topics.len.int64)

  if p.knownTopics.contains(topic):
    p.topics.withValue(topic, handlers) do:
      libp2p_pubsub_topic_handlers.set(handlers[].len.int64, labelValues = [topic])
    do:
      libp2p_pubsub_topic_handlers.set(0, labelValues = [topic])
  else:
    var others: int64 = 0
    for key, val in p.topics:
      if key notin p.knownTopics: others += 1

    libp2p_pubsub_topic_handlers.set(others, labelValues = ["other"])

method onTopicSubscription*(p: PubSub, topic: string, subscribed: bool) {.base, gcsafe.} =
  # Called when subscribe is called the first time for a topic or unsubscribe
  # removes the last handler

  # Notify others that we are no longer interested in the topic
  for _, peer in p.peers:
    # If we don't have a sendConn yet, we will
    # send the full sub list when we get the sendConn,
    # so no need to send it here
    if peer.hasSendConn:
      p.sendSubs(peer, [topic], subscribed)

  if subscribed:
    libp2p_pubsub_subscriptions.inc()
  else:
    libp2p_pubsub_unsubscriptions.inc()

proc unsubscribe*(p: PubSub,
                  topic: string,
                  handler: TopicHandler) {.public.} =
  ## unsubscribe from a ``topic`` string
  ##
  p.topics.withValue(topic, handlers):
    handlers[].keepItIf(it != handler)

    if handlers[].len() == 0:
      p.topics.del(topic)

      p.onTopicSubscription(topic, false)

    p.updateTopicMetrics(topic)

proc unsubscribe*(p: PubSub, topics: openArray[TopicPair]) {.public.} =
  ## unsubscribe from a list of ``topic`` handlers
  for t in topics:
    p.unsubscribe(t.topic, t.handler)

proc unsubscribeAll*(p: PubSub, topic: string) {.public, gcsafe.} =
  ## unsubscribe every `handler` from `topic`
  if topic notin p.topics:
    debug "unsubscribeAll called for an unknown topic", topic
  else:
    p.topics.del(topic)

    p.onTopicSubscription(topic, false)

    p.updateTopicMetrics(topic)

proc subscribe*(p: PubSub,
                topic: string,
                handler: TopicHandler) {.public.} =
  ## subscribe to a topic
  ##
  ## ``topic``   - a string topic to subscribe to
  ##
  ## ``handler`` - user provided proc that
  ##               will be triggered on every
  ##               received message

  # Check that this is an allowed topic
  if p.subscriptionValidator != nil and p.subscriptionValidator(topic) == false:
    warn "Trying to subscribe to a topic not passing validation!", topic
    return

  p.topics.withValue(topic, handlers) do:
    # Already subscribed, just adding another handler
    handlers[].add(handler)
  do:
    trace "subscribing to topic", name = topic
    p.topics[topic] = @[handler]

    # Notify on first handler
    p.onTopicSubscription(topic, true)

  p.updateTopicMetrics(topic)

method publish*(p: PubSub,
                topic: string,
                data: seq[byte]): Future[int] {.base, async, public.} =
  ## publish to a ``topic``
  ##
  ## The return value is the number of neighbours that we attempted to send the
  ## message to, excluding self. Note that this is an optimistic number of
  ## attempts - the number of peers that actually receive the message might
  ## be lower.
  if p.triggerSelf:
    await handleData(p, topic, data)

  return 0

method initPubSub*(p: PubSub)
  {.base, raises: [InitializationError].} =
  ## perform pubsub initialization
  p.observers = new(seq[PubSubObserver])
  if p.msgIdProvider == nil:
    p.msgIdProvider = defaultMsgIdProvider

method addValidator*(p: PubSub,
                     topic: varargs[string],
                     hook: ValidatorHandler) {.base, public, gcsafe.} =
  ## Add a validator to a `topic`. Each new message received in this
  ## will be sent to `hook`. `hook` can return either `Accept`,
  ## `Ignore` or `Reject` (which can descore the peer)
  for t in topic:
    trace "adding validator for topic", topicId = t
    p.validators.mgetOrPut(t, HashSet[ValidatorHandler]()).incl(hook)

method removeValidator*(p: PubSub,
                        topic: varargs[string],
                        hook: ValidatorHandler) {.base, public.} =
  for t in topic:
    p.validators.withValue(t, validators):
      validators[].excl(hook)
      if validators[].len() == 0:
        p.validators.del(t)

method validate*(p: PubSub, message: Message): Future[ValidationResult] {.async, base.} =
  var pending: seq[Future[ValidationResult]]
  trace "about to validate message"
  let topic = message.topicId
  trace "looking for validators on topic",
    topicId = topic, registered = toSeq(p.validators.keys)
  if topic in p.validators:
    trace "running validators for topic", topicId = topic
    for validator in p.validators[topic]:
      pending.add(validator(topic, message))

  result = ValidationResult.Accept
  let futs = await allFinished(pending)
  for fut in futs:
    if fut.failed:
      result = ValidationResult.Reject
      break
    let res = fut.read()
    if res != ValidationResult.Accept:
      result = res
      if res == ValidationResult.Reject:
        break

  case result
  of ValidationResult.Accept:
    libp2p_pubsub_validation_success.inc()
  of ValidationResult.Reject:
    libp2p_pubsub_validation_failure.inc()
  of ValidationResult.Ignore:
    libp2p_pubsub_validation_ignore.inc()

proc init*[PubParams: object | bool](
  P: typedesc[PubSub],
  switch: Switch,
  triggerSelf: bool = false,
  anonymize: bool = false,
  verifySignature: bool = true,
  sign: bool = true,
  msgIdProvider: MsgIdProvider = defaultMsgIdProvider,
  subscriptionValidator: SubscriptionValidator = nil,
  maxMessageSize: int = 1024 * 1024,
  rng: ref HmacDrbgContext = newRng(),
  parameters: PubParams = false): P
  {.raises: [InitializationError], public.} =
  let pubsub =
    when PubParams is bool:
      P(switch: switch,
        peerInfo: switch.peerInfo,
        triggerSelf: triggerSelf,
        anonymize: anonymize,
        verifySignature: verifySignature,
        sign: sign,
        msgIdProvider: msgIdProvider,
        subscriptionValidator: subscriptionValidator,
        maxMessageSize: maxMessageSize,
        rng: rng,
        topicsHigh: int.high)
    else:
      P(switch: switch,
        peerInfo: switch.peerInfo,
        triggerSelf: triggerSelf,
        anonymize: anonymize,
        verifySignature: verifySignature,
        sign: sign,
        msgIdProvider: msgIdProvider,
        subscriptionValidator: subscriptionValidator,
        parameters: parameters,
        maxMessageSize: maxMessageSize,
        rng: rng,
        topicsHigh: int.high)

  proc peerEventHandler(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      pubsub.subscribePeer(peerId)
    else:
      pubsub.unsubscribePeer(peerId)

  switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  pubsub.knownTopics = KnownLibP2PTopicsSeq.toHashSet()

  pubsub.initPubSub()

  return pubsub

proc addObserver*(p: PubSub; observer: PubSubObserver) {.public.} = p.observers[] &= observer

proc removeObserver*(p: PubSub; observer: PubSubObserver) {.public.} =
  let idx = p.observers[].find(observer)
  if idx != -1:
    p.observers[].del(idx)
