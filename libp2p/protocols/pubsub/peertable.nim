# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[tables, sets, sequtils, strutils]
import ./pubsubpeer, ../../peerid

export tables, sets

type PeerTable* = Table[string, HashSet[PubSubPeer]] # topic string to peer map

proc `$`*(table: PeerTable): string =
  result.add("PeerTable ")
  result.add("topics (" & $table.len & ")")

  for topic, peers in table:
    result.add(" topic: ")
    result.add($topic)
    result.add(" peers: ")
    result.add("(" & $peers.len & ") [")
    result.add(peers.mapIt($it).join(", "))
    result.add("]")

proc hasPeerId*(t: PeerTable, topic: string, peerId: PeerId): bool =
  if topic in t:
    try:
      for peer in t[topic]:
        if peer.peerId == peerId:
          return true
    except KeyError:
      raiseAssert "checked with in"
  false

func addPeer*(table: var PeerTable, topic: string, peer: PubSubPeer): bool =
  # returns true if the peer was added,
  # false if it was already in the collection
  not table.mgetOrPut(topic, initHashSet[PubSubPeer]()).containsOrIncl(peer)

func removePeer*(table: var PeerTable, topic: string, peer: PubSubPeer) =
  table.withValue(topic, peers):
    peers[].excl(peer)
    if peers[].len == 0:
      table.del(topic)

func hasPeer*(table: PeerTable, topic: string, peer: PubSubPeer): bool =
  try:
    (topic in table) and (peer in table[topic])
  except KeyError:
    raiseAssert "checked with in"

func peers*(table: PeerTable, topic: string): int =
  if topic in table:
    try:
      table[topic].len
    except KeyError:
      raiseAssert "checked with in"
  else:
    0

func outboundPeers*(table: PeerTable, topic: string): int =
  if topic in table:
    try:
      table[topic].countIt(it.outbound)
    except KeyError:
      raiseAssert "checked with in"
  else:
    0
