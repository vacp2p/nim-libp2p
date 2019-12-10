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
                        data: seq[byte]): Future[void] {.gcsafe.}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  Topic* = object
    name*: string
    handler*: seq[TopicHandler]

  PubSub* = ref object of LPProtocol
    peerInfo*: PeerInfo               # this peer's info
    topics*: Table[string, Topic]     # local topics
    peers*: Table[string, PubSubPeer] # peerid to peer map
    triggerSelf*: bool                # trigger own local handler on publish
    cleanupLock: AsyncLock

proc sendSubs*(p: PubSub,
               peer: PubSubPeer,
               topics: seq[string],
               subscribe: bool) {.async, gcsafe.} =
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
  if peer.id in p.peers:
    p.peers.del(peer.id)

proc cleanUpHelper(p: PubSub, peer: PubSubPeer) {.async.} =
  await p.cleanupLock.acquire()
  if peer.refs == 0:
    await p.handleDisconnect(peer)

  peer.refs.dec() # decrement refcount
  p.cleanupLock.release()

proc getPeer(p: PubSub, peerInfo: PeerInfo, proto: string): PubSubPeer =
  if peerInfo.id in p.peers:
    result = p.peers[peerInfo.id]
    return

  # create new pubsub peer
  let peer = newPubSubPeer(peerInfo, proto)
  trace "created new pubsub peer", peerId = peer.id

  p.peers[peer.id] = peer
  peer.refs.inc # increment reference cound
  result = peer

method handleConn*(p: PubSub,
                   conn: Connection,
                   proto: string) {.base, async, gcsafe.} =
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

  if conn.peerInfo.isNone:
    trace "no valid PeerId for peer"
    await conn.close()
    return

  proc handler(peer: PubSubPeer, msgs: seq[RPCMsg]) {.async, gcsafe.} =
    # call floodsub rpc handler
    await p.rpcHandler(peer, msgs)

  let peer = p.getPeer(conn.peerInfo.get(), proto)
  let topics = toSeq(p.topics.keys)
  if topics.len > 0:
    await p.sendSubs(peer, topics, true)

  peer.handler = handler
  await peer.handle(conn) # spawn peer read loop
  trace "pubsub peer handler ended, cleaning up"
  await p.cleanUpHelper(peer)

method subscribeToPeer*(p: PubSub,
                        conn: Connection) {.base, async, gcsafe.} =
  var peer = p.getPeer(conn.peerInfo.get(), p.codec)
  trace "setting connection for peer", peerId = conn.peerInfo.get().id
  if not peer.isConnected:
    peer.conn = conn

  # handle connection close
  conn.closeEvent.wait()
  .addCallback do (udata: pointer = nil):
    trace "connection closed, cleaning up peer",
      peer = conn.peerInfo.get().id

    asyncCheck p.cleanUpHelper(peer)

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

method start*(p: PubSub) {.async, base.} =
  ## start pubsub
  ## start long running/repeating procedures
  discard

method stop*(p: PubSub) {.async, base.} =
  ## stopt pubsub
  ## stop long running/repeating procedures
  discard

proc newPubSub*(p: typedesc[PubSub],
                peerInfo: PeerInfo,
                triggerSelf: bool = false): p =
  new result
  result.peerInfo = peerInfo
  result.triggerSelf = triggerSelf
  result.cleanupLock = newAsyncLock()
  result.initPubSub()
