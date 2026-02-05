# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/tables
import results
import ../libp2p
import ../libp2p/protocols/pubsub/gossipsub
import ../libp2p/protocols/kademlia
import ../libp2p/protocols/mix
import ../libp2p/protocols/mix/mix_node
import ffi_types

# TODO: remove and implement custom event callbacks if needed
# Example:
#   proc onSomeEvent(ctx: ptr LibP2PContext): Libp2pCallback =
#    return proc(msg: string) {.gcsafe.} =
#      callEventCallback(ctx, "onSomeEvent"):
#        $JsonMyEvent.new(msg)
type AppCallbacks* = ref object

type PubsubTopicPair* = tuple[topic: string, handler: PubsubTopicHandler]
type TopicHandlerEntry* = tuple[handler: TopicHandler, userData: pointer]

type LibP2P* = ref object
  switch*: Switch
  gossipSub*: Opt[GossipSub]
  kad*: Opt[KadDHT]
  mix*: Opt[MixProtocol]
  mixNodeInfo*: Opt[MixNodeInfo]
  topicHandlers*: Table[PubsubTopicPair, TopicHandlerEntry]
  connections*: Table[ptr Libp2pStream, Connection]
