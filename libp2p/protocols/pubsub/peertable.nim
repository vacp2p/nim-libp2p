## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, sets
import pubsubpeer, ../../peerid

type
  PeerTable* = Table[string, HashSet[PubSubPeer]] # topic string to peer map

proc hasPeerID*(t: PeerTable, topic: string, peerId: PeerID): bool =
  if topic in t:
    for peer in t[topic]:
      if peer.peerId == peerId:
        return true
  false

func addPeer*(table: var PeerTable, topic: string, peer: PubSubPeer): bool =
  # returns true if the peer was added,
  # false if it was already in the collection
  not table.mgetOrPut(topic,
    initHashSet[PubSubPeer]())
    .containsOrIncl(peer)

func removePeer*(table: var PeerTable, topic: string, peer: PubSubPeer) =
  table.withValue(topic, peers):
    peers[].excl(peer)
    if peers[].len == 0:
      table.del(topic)

func hasPeer*(table: PeerTable, topic: string, peer: PubSubPeer): bool =
  (topic in table) and (peer in table[topic])

func peers*(table: PeerTable, topic: string): int =
  if topic in table:
    table[topic].len
  else:
    0

func getPeers*(table: Table[string, HashSet[string]], topic: string): HashSet[string] =
  table.getOrDefault(topic, initHashSet[string]())
