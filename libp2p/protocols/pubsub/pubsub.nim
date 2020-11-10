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

import metrics
import stew/results
export results

export PubSubPeer
export PubSubObserver
export protocol

logScope:
  topics = "pubsub"

declareGauge(libp2p_pubsub_peers, "pubsub peer instances")
declareGauge(libp2p_pubsub_topics, "pubsub subscribed topics")
declareCounter(libp2p_pubsub_validation_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_validation_failure, "pubsub failed validated messages")
declareCounter(libp2p_pubsub_validation_ignore, "pubsub ignore validated messages")
when defined(libp2p_expensive_metrics):
  declarePublicCounter(libp2p_pubsub_messages_published, "published messages", labels = ["topic"])

type
  TopicHandler* = proc(topic: string,
                       data: seq[byte]): Future[void] {.gcsafe.}

  ValidationResult* {.pure.} = enum
    Accept, Reject, Ignore

  ValidatorHandler* = proc(topic: string,
                           message: Message): Future[ValidationResult] {.gcsafe, closure.}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  MsgIdProvider* =
    proc(m: Message): MessageID {.noSideEffect, raises: [Defect], nimcall, gcsafe.}

  Topic* = object
    # make this a variant type if one day we have different Params structs
    name*: string
    handler*: seq[TopicHandler]

  PubSub* = ref object of LPProtocol
    switch*: Switch                    # the switch used to dial/connect to peers
    peerInfo*: PeerInfo                # this peer's info
    topics*: Table[string, Topic]      # local topics
    peers*: Table[PeerID, PubSubPeer]  ##\
      ## Peers that we are interested to gossip with (but not necessarily
      ## yet connected to)
    triggerSelf*: bool                 # trigger own local handler on publish
    verifySignature*: bool             # enable signature verification
    sign*: bool                        # enable message signing
    validators*: Table[string, HashSet[ValidatorHandler]]
    observers: ref seq[PubSubObserver] # ref as in smart_ptr
    msgIdProvider*: MsgIdProvider      # Turn message into message id (not nil)
    msgSeqno*: uint64
    anonymize*: bool                   # if we omit fromPeer and seqno from RPC messages we send

method unsubscribePeer*(p: PubSub, peerId: PeerID) {.base.} =
  ## handle peer disconnects
  ##

  debug "unsubscribing pubsub peer", peerId
  p.peers.del(peerId)

  libp2p_pubsub_peers.set(p.peers.len.int64)

proc send*(p: PubSub, peer: PubSubPeer, msg: RPCMsg) =
  ## Attempt to send `msg` to remote peer
  ##

  trace "sending pubsub message to peer", peer, msg = shortLog(msg)
  peer.send(msg, p.anonymize)

proc broadcast*(
  p: PubSub,
  sendPeers: openArray[PubSubPeer],
  msg: RPCMsg) = # raises: [Defect]
  ## Attempt to send `msg` to the given peers

  trace "broadcasting messages to peers",
    peers = sendPeers.len, msg = shortLog(msg)
  for peer in sendPeers:
    p.send(peer, msg)

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: seq[string],
               subscribe: bool) =
  ## send subscriptions to remote peer
  p.send(peer, RPCMsg.withSubs(topics, subscribe))

method subscribeTopic*(p: PubSub,
                       topic: string,
                       subscribe: bool,
                       peer: PubSubPeer) {.base.} =
  # called when remote peer subscribes to a topic
  discard

method rpcHandler*(p: PubSub,
                   peer: PubSubPeer,
                   rpcMsg: RPCMsg) {.async, base.} =
  ## handle rpc messages
  trace "processing RPC message", msg = rpcMsg.shortLog, peer
  for s in rpcMsg.subscriptions: # subscribe/unsubscribe the peer for each topic
    trace "about to subscribe to topic", topicId = s.topic, peer
    p.subscribeTopic(s.topic, s.subscribe, peer)

method onNewPeer(p: PubSub, peer: PubSubPeer) {.base.} = discard

method onPubSubPeerEvent*(p: PubSub, peer: PubsubPeer, event: PubsubPeerEvent) {.base, gcsafe.} =
  # Peer event is raised for the send connection in particular
  case event.kind
  of PubSubPeerEventKind.Connected:
    if p.topics.len > 0:
      p.sendSubs(peer, toSeq(p.topics.keys), true)
  of PubSubPeerEventKind.Disconnected:
    discard

proc getOrCreatePeer*(
  p: PubSub,
  peer: PeerID,
  protos: seq[string]): PubSubPeer =
  if peer in p.peers:
    return p.peers[peer]

  proc getConn(): Future[Connection] =
    p.switch.dial(peer, protos)

  proc onEvent(peer: PubsubPeer, event: PubsubPeerEvent) {.gcsafe.} =
    p.onPubSubPeerEvent(peer, event)

  # create new pubsub peer
  let pubSubPeer = newPubSubPeer(peer, getConn, onEvent, protos[0])
  debug "created new pubsub peer", peer

  p.peers[peer] = pubSubPeer
  pubSubPeer.observers = p.observers

  onNewPeer(p, pubSubPeer)

  # metrics
  libp2p_pubsub_peers.set(p.peers.len.int64)

  pubsubPeer.connect()

  return pubSubPeer

proc handleData*(p: PubSub, topic: string, data: seq[byte]): Future[void] {.async.} =
  if topic notin p.topics: return # Not subscribed

  for h in p.topics[topic].handler:
    trace "triggering handler", topicID = topic
    try:
      await h(topic, data)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      # Handlers should never raise exceptions
      warn "Error in topic handler", msg = exc.msg

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

  proc handler(peer: PubSubPeer, msg: RPCMsg): Future[void] =
    # call pubsub rpc handler
    p.rpcHandler(peer, msg)

  let peer = p.getOrCreatePeer(conn.peerInfo.peerId, @[proto])

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

method subscribePeer*(p: PubSub, peer: PeerID) {.base.} =
  ## subscribe to remote peer to receive/send pubsub
  ## messages
  ##

  let peer = p.getOrCreatePeer(peer, p.codecs)
  peer.outbound = true # flag as outbound

method unsubscribe*(p: PubSub,
                    topics: seq[TopicPair]) {.base, async.} =
  ## unsubscribe from a list of ``topic`` strings
  for t in topics:
    let
      handler = t.handler
      ttopic = t.topic
    closureScope:
      p.topics.withValue(ttopic, topic):
        topic[].handler.keepIf(proc (x: auto): bool = x != handler)

        if topic[].handler.len == 0:
          # make sure we delete the topic if
          # no more handlers are left
          p.topics.del(ttopic)

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

  for _, peer in p.peers:
    p.sendSubs(peer, @[topic], true)

  # metrics
  libp2p_pubsub_topics.set(p.topics.len.int64)

method publish*(p: PubSub,
                topic: string,
                data: seq[byte]): Future[int] {.base, async.} =
  ## publish to a ``topic``
  ## The return value is the number of neighbours that we attempted to send the
  ## message to, excluding self. Note that this is an optimistic number of
  ## attempts - the number of peers that actually receive the message might
  ## be lower.
  if p.triggerSelf:
    await handleData(p, topic, data)

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

method validate*(p: PubSub, message: Message): Future[ValidationResult] {.async, base.} =
  var pending: seq[Future[ValidationResult]]
  trace "about to validate message"
  for topic in message.topicIDs:
    trace "looking for validators on topic", topicID = topic,
                                             registered = toSeq(p.validators.keys)
    if topic in p.validators:
      trace "running validators for topic", topicID = topic
      # TODO: add timeout to validator
      pending.add(p.validators[topic].mapIt(it(topic, message)))

  result = ValidationResult.Accept
  let futs = await allFinished(pending)
  for fut in futs:
    if fut.failed:
      result = ValidationResult.Reject
      break
    let res = fut.read()
    if res != ValidationResult.Accept:
      result = res
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
  parameters: PubParams = false): P =
  let pubsub =
    when PubParams is bool:
      P(switch: switch,
        peerInfo: switch.peerInfo,
        triggerSelf: triggerSelf,
        anonymize: anonymize,
        verifySignature: verifySignature,
        sign: sign,
        peers: initTable[PeerID, PubSubPeer](),
        topics: initTable[string, Topic](),
        msgIdProvider: msgIdProvider)
    else:
      P(switch: switch,
        peerInfo: switch.peerInfo,
        triggerSelf: triggerSelf,
        anonymize: anonymize,
        verifySignature: verifySignature,
        sign: sign,
        peers: initTable[PeerID, PubSubPeer](),
        topics: initTable[string, Topic](),
        msgIdProvider: msgIdProvider,
        parameters: parameters)

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event == PeerEvent.Joined:
      pubsub.subscribePeer(peerId)
    else:
      pubsub.unsubscribePeer(peerId)

  switch.addPeerEventHandler(peerEventHandler, PeerEvent.Joined)
  switch.addPeerEventHandler(peerEventHandler, PeerEvent.Left)

  pubsub.initPubSub()

  return pubsub


proc addObserver*(p: PubSub; observer: PubSubObserver) = p.observers[] &= observer

proc removeObserver*(p: PubSub; observer: PubSubObserver) =
  let idx = p.observers[].find(observer)
  if idx != -1:
    p.observers[].del(idx)
