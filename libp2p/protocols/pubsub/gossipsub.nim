## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables
import chronos, chronicles
import floodsub, pubsubpeer, rpcmsg

const GossipSubCodec = "/meshsub/1.0.0"

# overlay parameters
const GossipSubD   = 6
const GossipSubDlo = 4
const GossipSubDhi = 12

# gossip parameters
const GossipSubHistoryLength = 5
const GossipSubHistoryGossip = 3

# heartbeat interval
const GossipSubHeartbeatInitialDelay = 100.millis
const GossipSubHeartbeatInterval     = 1 * 1000.seconds

# fanout ttl
const GossipSubFanoutTTL = 60.seconds

type
  GossipSub* = ref object of FloodSub
    mesh*: Table[string, PubSubPeer] # topic meshes
    fanout*: Table[string, PubSubPeer] # topic fanout
    lastPubSub*: Table[string, Duration] # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]
    control*: Table[string, ControlMessage]


