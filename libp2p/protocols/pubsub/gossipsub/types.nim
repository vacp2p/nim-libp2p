# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import std/[options, tables, sets, heapqueue]
import ".."/[floodsub, peertable, mcache, pubsubpeer]
import "../rpc"/[messages]
import "../../.."/[peerid, multiaddress, utility]

export options, tables, sets

const
  GossipSubCodec_14* = "/meshsub/1.4.0"
  GossipSubCodec_12* = "/meshsub/1.2.0"
  GossipSubCodec_11* = "/meshsub/1.1.0"
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
const GossipSubFanoutTTL* = 1.minutes

# gossip parameters
const GossipBackoffPeriod* = 1.minutes

const
  BackoffSlackTime* = 2 # seconds
  PingsPeerBudget* = 100 # maximum of 6.4kb/heartbeat (6.4kb/s with default 1 second/hb)
  IHavePeerBudget* = 10
  PreamblePeerBudget* = 10
  PullOperation* = true
  # the max amount of IHave to expose, not by spec, but go as example
  # rust sigp: https://github.com/sigp/rust-libp2p/blob/f53d02bc873fef2bf52cd31e3d5ce366a41d8a8c/protocols/gossipsub/src/config.rs#L572
  # go: https://github.com/libp2p/go-libp2p-pubsub/blob/08c17398fb11b2ab06ca141dddc8ec97272eb772/gossipsub.go#L155
  IHaveMaxLength* = 5000
  IDontWantMaxCount* = 1000
    # maximum number of IDontWant messages in one slot of the history
  MaxOpportunisticGraftPeers* = 2

type
  TopicInfo* = object # gossip 1.1 related
    graftTime*: Moment
    meshTime*: Duration
    inMesh*: bool
    meshMessageDeliveriesActive*: bool
    firstMessageDeliveries*: float64
    meshMessageDeliveries*: float64
    meshFailurePenalty*: float64
    invalidMessageDeliveries*: float64

  PeerSet* = object
    order*: seq[PeerId]
    peers*: HashSet[PeerId]

  PreambleInfo* = ref object
    messageId*: MessageId
    messageLength*: uint32
    topicId*: string
    sender*: PubSubPeer
    startsAt*: Moment
    expiresAt*: Moment
    deleted*: bool # tombstone marker
    peerSet*: PeerSet

  PreambleStore* = object
    byId*: Table[MessageId, PreambleInfo]
    heap*: HeapQueue[PreambleInfo]

  TopicParams* {.public.} = object
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

  GossipSubParams* {.public.} = object
    # explicit is used to check if the GossipSubParams instance was created by the user either passing params to GossipSubParams(...)
    # or GossipSubParams.init(...). In the first case explicit should be set to true when calling the Nim constructor.
    # In the second case, the param isn't necessary and should be always be set to true by init.
    # If none of those options were used, it means the instance was created using Nim default values.
    # In this case, GossipSubParams.init() should be called when initing GossipSub to set the values to their default value defined by nim-libp2p.
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
    enablePX*: bool

    bandwidthEstimatebps*: int
      # This is currently used only for limting flood publishing. 0 disables flood-limiting completely

    overheadRateLimit*: Opt[tuple[bytes: int, interval: Duration]]
    disconnectPeerAboveRateLimit*: bool

    # Max number of elements allowed in the non-priority queue. When this limit has been reached, the peer will be disconnected.
    maxNumElementsInNonPriorityQueue*: int

    # Broadcast an IDONTWANT message automatically when the message exceeds the IDONTWANT message size threshold
    sendIDontWantOnPublish*: bool

  BackoffTable* = Table[string, Table[PeerId, Moment]]
  ValidationSeenTable* = Table[SaltedId, HashSet[PubSubPeer]]
  OngoingReceivesStore* = PreambleStore

  RoutingRecordsPair* = tuple[id: PeerId, record: Option[PeerRecord]]
  RoutingRecordsHandler* = proc(
    peer: PeerId,
    tag: string, # For gossipsub, the topic
    peers: seq[RoutingRecordsPair],
  ) {.gcsafe, raises: [].}

  GossipSub* = ref object of FloodSub
    mesh*: PeerTable # peers that we send messages to when we are subscribed to the topic
    fanout*: PeerTable
      # peers that we send messages to when we're not subscribed to the topic
    gossipsub*: PeerTable # peers that are subscribed to a topic
    subscribedDirectPeers*: PeerTable # directpeers that we keep alive
    backingOff*: BackoffTable # peers to backoff from when replenishing the mesh
    lastFanoutPubSub*: Table[string, Moment] # last publish time for fanout topics
    mcache*: MCache # messages cache
    validationSeen*: ValidationSeenTable # peers who sent us message in validation
    heartbeatFut*: Future[void] # cancellation future for heartbeat interval
    when defined(libp2p_gossipsub_1_4):
      preambleExpirationFut*: Future[void]
      # cancellation future for preamble expiration heartbeat interval
    scoringHeartbeatFut*: Future[void]
      # cancellation future for scoring heartbeat interval
    heartbeatRunning*: bool

    peerStats*: Table[PeerId, PeerStats]
    parameters*: GossipSubParams
    topicParams*: Table[string, TopicParams]
    directPeersLoop*: Future[void]
    peersInIP*: Table[MultiAddress, HashSet[PeerId]]
    routingRecordsHandler*: seq[RoutingRecordsHandler] # Callback for peer exchange

    heartbeatEvents*: seq[AsyncEvent]

    when defined(libp2p_gossipsub_1_4):
      ongoingReceives*: OngoingReceivesStore # list of messages we are receiving
      ongoingIWantReceives*: OngoingReceivesStore
        # list of iwant replies we are receiving

  MeshMetrics* = object # scratch buffers for metrics
    otherPeersPerTopicMesh*: int64
    otherPeersPerTopicFanout*: int64
    otherPeersPerTopicGossipsub*: int64
    noPeersTopics*: int64 # npeers == 0
    lowPeersTopics*: int64 # npeers < dlow
    healthyPeersTopics*: int64 # npeers >= dlow
    underDoutTopics*: int64
