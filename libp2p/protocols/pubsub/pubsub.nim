## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sets
import chronos, chronicles
import pubsubpeer,
       ../protocol,
       ../../connection,
       ../../peerinfo

export PubSubPeer

logScope:
  topic = "PubSub"

type
  TopicHandler* = proc (topic: string, 
                        data: seq[byte]): 
                        Future[void] {.closure, gcsafe.}

  TopicPair* = tuple[topic: string, handler: TopicHandler]

  Topic* = object
    name*: string
    handler*: seq[TopicHandler]

  PubSub* = ref object of LPProtocol
    peerInfo*: PeerInfo
    topics*: Table[string, Topic] # local topics
    peers*: Table[string, PubSubPeer] # peerid to peer map
    peerTopics*: Table[string, HashSet[string]] # topic to remote peer map

method subscribeToPeer*(p: PubSub, conn: Connection) {.base, async, gcsafe.} =
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

method subscribe*(p: PubSub,
                  topic: string,
                  handler: TopicHandler)
                  {.base, async, gcsafe.} = 
  ## subscribe to a topic
  ##
  ## ``topic``   - a string topic to subscribe to
  ##
  ## ``handler`` - is a user provided proc 
  ##               that will be triggered 
  ##               on every received message
  ##
  if not p.topics.contains(topic):
    p.topics[topic] = Topic(name: topic)
  
  p.topics[topic].handler.add(handler)

method publish*(p: PubSub, topic: string, data: seq[byte]) {.base, async, gcsafe.} = 
  ## publish to a ``topic``
  discard
