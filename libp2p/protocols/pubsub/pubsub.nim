## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sets
import chronos
import pubsubpeer,
       ../protocol,
       ../../connection,
       ../../peerinfo

export PubSubPeer

type
  TopicHandler* = proc(topic:string, data: seq[byte]): Future[void] {.gcsafe.}
  Topic* = object
    name*: string
    handler*: TopicHandler

  PubSub* = ref object of LPProtocol
    peerInfo*: PeerInfo
    topics*: Table[string, Topic] # local topics
    peers*: Table[string, PubSubPeer] # peerid to peer map
    peerTopics*: Table[string, HashSet[string]] # topic to remote peer map

method subscribePeer*(p: PubSub, conn: Connection) {.base, async, gcsafe.} =
  ## subscribe to a peer to send/receive pubsub messages
  discard

method unsubscribe*(p: PubSub, topics: seq[string]) {.base, async, gcsafe.} = 
  ## unsubscribe from a list of ``topic`` strings
  discard

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
  p.topics[topic] = Topic(name: topic, handler: handler)

method publish*(p: PubSub, topic: string, data: seq[byte]) {.base, async, gcsafe.} = 
  ## publish to a ``topic``
  discard
