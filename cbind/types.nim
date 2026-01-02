# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/tables
import ../libp2p
import ../libp2p/protocols/pubsub/gossipsub
import ../libp2p/protocols/kademlia
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
  gossipSub*: GossipSub
  kad*: KadDHT
  topicHandlers*: Table[PubsubTopicPair, TopicHandlerEntry]
  connections*: Table[ptr Libp2pStream, Connection]
