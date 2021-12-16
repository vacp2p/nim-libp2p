## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import chronos
import std/[tables, sets]
import ".."/[floodsub, peertable, mcache, pubsubpeer]
import "../rpc"/[messages]
import "../../.."/[peerid, multiaddress]

const
  GossipSubCodec* = "/meshsub/1.1.0"
  GossipSubCodec_10* = "/meshsub/1.0.0"

# overlay parameters
const
  GossipSubD* = 6
  GossipSubDlo* = 4
  GossipSubDhi* = 12

# gossip parameters
const
  GossipSubHistoryLength* = 5
  GossipSubHistoryGossip* = 3

# heartbeat interval
  GossipSubHeartbeatInterval* = 1.seconds

# fanout ttl
const
  GossipSubFanoutTTL* = 1.minutes

# gossip parameters
const
  GossipBackoffPeriod* = 1.minutes

const
  BackoffSlackTime* = 2 # seconds
  IWantPeerBudget* = 25 # 25 messages per second ( reset every heartbeat )
  IHavePeerBudget* = 10
  # the max amount of IHave to expose, not by spec, but go as example
  # rust sigp: https://github.com/sigp/rust-libp2p/blob/f53d02bc873fef2bf52cd31e3d5ce366a41d8a8c/protocols/gossipsub/src/config.rs#L572
  # go: https://github.com/libp2p/go-libp2p-pubsub/blob/08c17398fb11b2ab06ca141dddc8ec97272eb772/gossipsub.go#L155
  IHaveMaxLength* = 5000

type
  TopicInfo* = object
    # gossip 1.1 related
    graftTime*: Moment
    meshTime*: Duration
    inMesh*: bool
    meshMessageDeliveriesActive*: bool
    firstMessageDeliveries*: float64
    meshMessageDeliveries*: float64
    meshFailurePenalty*: float64
    invalidMessageDeliveries*: float64

  TopicParams* = object
    topicWeight*: float64

    # p1
    timeInMeshWeight*: float64
    timeInMeshQuantum*: Duration
    timeInMeshCap*: float64

    # p2
    firstMessageDeliveriesWeight*: float64
    firstMessageDeliveriesDecay*: float64
    firstMessageDeliveriesCap*: float64

    # p3
    meshMessageDeliveriesWeight*: float64
    meshMessageDeliveriesDecay*: float64
    meshMessageDeliveriesThreshold*: float64
    meshMessageDeliveriesCap*: float64
    meshMessageDeliveriesActivation*: Duration
    meshMessageDeliveriesWindow*: Duration

    # p3b
    meshFailurePenaltyWeight*: float64
    meshFailurePenaltyDecay*: float64

    # p4
    invalidMessageDeliveriesWeight*: float64
    invalidMessageDeliveriesDecay*: float64

  PeerStats* = object
    topicInfos*: Table[string, TopicInfo]
    expire*: Moment # updated on disconnect, to retain scores until expire
    # the following are copies from PubSubPeer, in order to restore them on re-connection
    score*: float64 # a copy of the score to keep in case the peer is disconnected
    appScore*: float64 # application specific score
    behaviourPenalty*: float64 # the eventual penalty score

  GossipSubParams* = object
    explicit*: bool
    pruneBackoff*: Duration
    unsubscribeBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float64
    d*: int
    dLow*: int
    dHigh*: int
    dScore*: int
    dOut*: int
    dLazy*: int

    heartbeatInterval*: Duration

    historyLength*: int
    historyGossip*: int

    fanoutTTL*: Duration
    seenTTL*: Duration

    gossipThreshold*: float64
    publishThreshold*: float64
    graylistThreshold*: float64
    acceptPXThreshold*: float64
    opportunisticGraftThreshold*: float64
    decayInterval*: Duration
    decayToZero*: float64
    retainScore*: Duration

    appSpecificWeight*: float64
    ipColocationFactorWeight*: float64
    ipColocationFactorThreshold*: float64
    behaviourPenaltyWeight*: float64
    behaviourPenaltyDecay*: float64

    directPeers*: Table[PeerId, seq[MultiAddress]]

    disconnectBadPeers*: bool

  BackoffTable* = Table[string, Table[PeerId, Moment]]
  ValidationSeenTable* = Table[MessageID, HashSet[PubSubPeer]]

  GossipSub* = ref object of FloodSub
    mesh*: PeerTable                           # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable                         # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable                      # peers that are subscribed to a topic
    explicit*: PeerTable                       # directpeers that we keep alive explicitly
    backingOff*: BackoffTable                  # peers to backoff from when replenishing the mesh
    lastFanoutPubSub*: Table[string, Moment]   # last publish time for fanout topics
    gossip*: Table[string, seq[ControlIHave]]  # pending gossip
    control*: Table[string, ControlMessage]    # pending control messages
    mcache*: MCache                            # messages cache
    validationSeen*: ValidationSeenTable       # peers who sent us message in validation
    heartbeatFut*: Future[void]                 # cancellation future for heartbeat interval
    heartbeatRunning*: bool

    peerStats*: Table[PeerId, PeerStats]
    parameters*: GossipSubParams
    topicParams*: Table[string, TopicParams]
    directPeersLoop*: Future[void]
    peersInIP*: Table[MultiAddress, HashSet[PeerId]]

    heartbeatEvents*: seq[AsyncEvent]

  MeshMetrics* = object
    # scratch buffers for metrics
    otherPeersPerTopicMesh*: int64
    otherPeersPerTopicFanout*: int64
    otherPeersPerTopicGossipsub*: int64
    noPeersTopics*: int64 # npeers == 0
    lowPeersTopics*: int64 # npeers < dlow
    healthyPeersTopics*: int64 # npeers >= dlow
    underDoutTopics*: int64
