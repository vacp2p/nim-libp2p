## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, options, sequtils
import chronos, chronicles
import pubsubpeer,
       rpc/messages,
       ../protocol,
       ../../connection,
       ../../peerinfo,
       ../../peer

export PubSubPeer

logScope:
  topic = "PubSub"

type
  TopicHandler* = proc (topic: string,
                        data: seq[byte]): Future[void] {.closure, gcsafe.}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  Topic* = object
    name*: string
    handler*: seq[TopicHandler]

  PubSub* = ref object of LPProtocol
    peerInfo*: PeerInfo # this peer's info
    topics*: Table[string, Topic] # local topics
    peers*: Table[string, PubSubPeer] # peerid to peer map
    triggerSelf*: bool # trigger own local handler on publish

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: seq[string],
               subscribe: bool) {.async, gcsafe.} =
  writeStackTrace()
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

method rpcHandler*(p: PubSub,
                   peer: PubSubPeer,
                   rpcMsgs: seq[RPCMsg]) {.async, base, gcsafe.} =
  ## handle rpc messages
  discard

method handleDisconnect*(p: PubSub, peer: PubSubPeer) {.async, base, gcsafe.} = 
  ## handle peer disconnects
  p.peers.del(peer.id)

method handleConn*(p: PubSub,
                   conn: Connection,
                   proto: string) {.base, async, gcsafe.} =
  ## handle incoming/outgoing connections
  ##
  ## this proc will:
  ## 1) register a new PubSubPeer for the connection
  ## 2) register a handler with the peer;
  ##    this handler gets called on every rpc message
  ##    that the peer receives
  ## 3) ask the peer to subscribe us to every topic
  ##    that we're interested in
  ##

  if conn.peerInfo.peerId.isNone:
    debug "no valid PeerId for peer"
    return

  proc handler(peer: PubSubPeer, msgs: seq[RPCMsg]) {.async, gcsafe.} =
      # call floodsub rpc handler
      await p.rpcHandler(peer, msgs)

  if conn.peerInfo.peerId.get().pretty notin p.peers:
    # create new pubsub peer
    var peer = newPubSubPeer(conn, handler, proto)

    trace "created new pubsub peer", id = peer.id

    p.peers[peer.id] = peer
    let topics = toSeq(p.topics.keys)
    if topics.len > 0:
      await p.sendSubs(peer, topics, true)

    let handlerFut = peer.handle() # spawn peer read loop
    handlerFut.addCallback(
      proc(udata: pointer = nil) {.gcsafe.} = 
        trace "pubsub peer handler ended, cleaning up",
          peer = conn.peerInfo.peerId.get().pretty

        # TODO: figureout how to handle properly without dicarding
        asyncDiscard p.handleDisconnect(peer)
    )

method subscribeToPeer*(p: PubSub,
                        conn: Connection) {.base, async, gcsafe.} =
  ## subscribe to a peer to send/receive pubsub messages
  discard

method unsubscribe*(p: PubSub,
                    topics: seq[TopicPair]) {.base, async, gcsafe.} = 
  ## unsubscribe from a list of ``topic`` strings
  for t in topics:
    for i, h in p.topics[t.topic].handler:
      if h == t.handler:
        p.topics[t.topic].handler.del(i)

method unsubscribe*(p: PubSub,
                    topic: string,
                    handler: TopicHandler): Future[void] {.base, gcsafe.} =
  ## unsubscribe from a ``topic`` string
  result = p.unsubscribe(@[(topic, handler)])

method subscribeTopic*(p: PubSub,
                       topic: string,
                       subscribe: bool,
                       peerId: string) {.base, gcsafe.} = 
  discard

method subscribe*(p: PubSub,
                  topic: string,
                  handler: TopicHandler) {.base, async, gcsafe.} = 
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

method publish*(p: PubSub,
                topic: string,
                data: seq[byte]) {.base, async, gcsafe.} = 
  ## publish to a ``topic``
  if p.triggerSelf and topic in p.topics:
    for h in p.topics[topic].handler:
      await h(topic, data)

method initPubSub*(p: PubSub) {.base.} =
  ## perform pubsub initializaion 
  discard

proc newPubSub*(p: typedesc[PubSub],
                peerInfo: PeerInfo,
                triggerSelf: bool = false): p =
  new result
  result.peerInfo = peerInfo
  result.triggerSelf = triggerSelf
  result.initPubSub()
