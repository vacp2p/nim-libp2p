## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[tables, sets]
import ./pubsubpeer, ../../peerid

type
  PeerTable* = Table[string, HashSet[PubSubPeer]] # topic string to peer map

proc hasPeerId*(t: PeerTable, topic: string, peerId: PeerId): bool =
  if topic in t:
    try:
      for peer in t[topic]:
        if peer.peerId == peerId:
          return true
    except KeyError: raiseAssert "checked with in"
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
  try:
    (topic in table) and (peer in table[topic])
  except KeyError: raiseAssert "checked with in"

func peers*(table: PeerTable, topic: string): int =
  if topic in table:
    try: table[topic].len
    except KeyError: raiseAssert "checked with in"
  else:
    0
