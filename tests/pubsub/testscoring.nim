# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import sequtils
import std/[options, tables, sets]
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, pubsubpeer]
import ../../libp2p/protocols/pubsub/gossipsub/[types, scoring]
import ../../libp2p/muxers/muxer
import ../../libp2p/[multiaddress, peerid]
import ../helpers

suite "GossipSub Scoring":
  teardown:
    checkTrackers()

  asyncTest "Disconnect bad peers":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(30, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0

    for i, peer in peers:
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      let conn = conns[i]
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

  asyncTest "Basic score calculation for mesh peers":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(5, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Set up topic parameters for scoring
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 2.0, # Multiplies the final topic score by 2
      timeInMeshWeight: 0.1, # Weight for time spent in mesh
      timeInMeshQuantum: 1.seconds, # Time quantum for mesh scoring
      timeInMeshCap: 10.0, # Maximum time in mesh score
      firstMessageDeliveriesWeight: 1.0, # Weight for first message deliveries
      firstMessageDeliveriesDecay: 0.5, # Not used in this test
      firstMessageDeliveriesCap: 10.0, # Not used in this test
    )

    # Initialize peer stats with calculated values for a round score
    let now = Moment.now()
    for peer in peers:
      gossipSub.withPeerStats(peer.peerId) do(stats: var PeerStats):
        stats.topicInfos[topic] = TopicInfo(
          inMesh: true,
          graftTime: now - 10.seconds, # 10 seconds in mesh
          firstMessageDeliveries: 1.5, # 1.5 first message deliveries
        )

    gossipSub.updateScores()

    # Score calculation breakdown:
    # P1 (time in mesh): meshTime / timeInMeshQuantum * timeInMeshWeight
    #                   = 10.0 / 1.0 * 0.1 = 1.0
    # P2 (first msg deliveries): firstMessageDeliveries * firstMessageDeliveriesWeight
    #                           = 1.5 * 1.0 = 1.5
    # Topic score = (P1 + P2) * topicWeight = (1.0 + 1.5) * 2.0 = 5.0
    # Final peer score = 5.0 (no app score, behavior penalty, or colocation factor)

    check:
      peers.allIt(it.score == 5.0)

  asyncTest "Time in mesh scoring (P1)":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(3, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      timeInMeshWeight: 0.1,
      timeInMeshQuantum: 1.seconds,
      timeInMeshCap: 5.0,
    )

    let now = Moment.now()

    # Set different mesh times for peers
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true, graftTime: now - 2.seconds # 2 seconds in mesh
      )

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 10.seconds, # 10 seconds in mesh (should be capped)
      )

    gossipSub.withPeerStats(peers[2].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: false # Not in mesh
      )

    gossipSub.updateScores()

    # Peer 0: 2 seconds * 0.1 = 0.2
    check abs(peers[0].score - 0.2) < 0.001
    # Peer 1: capped at 5.0 * 0.1 = 0.5
    check abs(peers[1].score - 0.5) < 0.001
    # Peer 2: not in mesh, score should be 0
    check peers[2].score == 0.0

  asyncTest "First message deliveries scoring (P2)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      firstMessageDeliveriesWeight: 2.0,
      firstMessageDeliveriesDecay: 0.9,
    )

    # Set different first message delivery counts
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 5.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 0.0)

    gossipSub.withPeerStats(peers[2].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 3.0)

    gossipSub.updateScores()

    # Check scores: firstMessageDeliveries * weight
    check peers[0].score == 10.0 # 5.0 * 2.0
    check peers[1].score == 0.0 # 0.0 * 2.0
    check peers[2].score == 6.0 # 3.0 * 2.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check stats[].topicInfos[topic].firstMessageDeliveries == 4.5 # 5.0 * 0.9

  asyncTest "Mesh message deliveries scoring (P3)":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(3, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    let now = Moment.now()
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      meshMessageDeliveriesWeight: -1.0,
      meshMessageDeliveriesThreshold: 5.0,
      meshMessageDeliveriesActivation: 1.seconds,
      meshMessageDeliveriesDecay: 0.8,
    )

    # Set up peers with different mesh message delivery counts
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 2.seconds,
        meshMessageDeliveries: 3.0, # Below threshold
        meshMessageDeliveriesActive: true,
      )

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 2.seconds,
        meshMessageDeliveries: 6.0, # Above threshold
        meshMessageDeliveriesActive: true,
      )

    gossipSub.withPeerStats(peers[2].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 500.milliseconds, # Recently grafted, not active yet
        meshMessageDeliveries: 2.0,
      )

    gossipSub.updateScores()

    # Peer 0: deficit = 5 - 3 = 2, penalty = 2^2 * -1 = -4
    check peers[0].score == -4.0
    # Peer 1: above threshold, no penalty
    check peers[1].score == 0.0
    # Peer 2: not active yet, no penalty
    check peers[2].score == 0.0

  asyncTest "Mesh failure penalty scoring (P3b)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(2, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0, meshFailurePenaltyWeight: -2.0, meshFailurePenaltyDecay: 0.7
    )

    # Set mesh failure penalty
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(meshFailurePenalty: 3.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(meshFailurePenalty: 0.0)

    gossipSub.updateScores()

    # Check penalty application
    check peers[0].score == -6.0 # 3.0 * -2.0
    check peers[1].score == 0.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check abs(stats[].topicInfos[topic].meshFailurePenalty - 2.1) < 0.001 # 3.0 * 0.7

  asyncTest "Invalid message deliveries scoring (P4)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(2, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      invalidMessageDeliveriesWeight: -3.0,
      invalidMessageDeliveriesDecay: 0.6,
    )

    # Set invalid message deliveries
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(invalidMessageDeliveries: 2.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(invalidMessageDeliveries: 0.0)

    gossipSub.updateScores()

    # Check penalty: 2^2 * -3 = -12
    check peers[0].score == -12.0
    check peers[1].score == 0.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check stats[].topicInfos[topic].invalidMessageDeliveries == 1.2 # 2.0 * 0.6

  asyncTest "App-specific scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.appSpecificWeight = 0.5

    # Set different app scores
    peers[0].appScore = 10.0
    peers[1].appScore = -5.0
    peers[2].appScore = 0.0

    gossipSub.updateScores()

    check peers[0].score == 5.0 # 10.0 * 0.5
    check peers[1].score == -2.5 # -5.0 * 0.5
    check peers[2].score == 0.0 # 0.0 * 0.5

  asyncTest "Behaviour penalty scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.behaviourPenaltyWeight = -0.1
    gossipSub.parameters.behaviourPenaltyDecay = 0.8

    # Set different behaviour penalties
    peers[0].behaviourPenalty = 5.0
    peers[1].behaviourPenalty = 2.0
    peers[2].behaviourPenalty = 0.0

    gossipSub.updateScores()

    # Check penalty: penalty^2 * weight
    check peers[0].score == -2.5 # 5^2 * -0.1 = -2.5
    check peers[1].score == -0.4 # 2^2 * -0.1 = -0.4
    check peers[2].score == 0.0 # 0^2 * -0.1 = 0.0

    # Check decay was applied
    check peers[0].behaviourPenalty == 4.0 # 5.0 * 0.8
    check peers[1].behaviourPenalty == 1.6 # 2.0 * 0.8
    check peers[2].behaviourPenalty == 0.0

  asyncTest "Colocation factor scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(5, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.ipColocationFactorWeight = -0.5
    gossipSub.parameters.ipColocationFactorThreshold = 2.0

    # Simulate peers from same IP
    let sharedAddress = MultiAddress.init("/ip4/192.168.1.1/tcp/4001").tryGet()
    peers[0].address = some(sharedAddress)
    peers[1].address = some(sharedAddress)
    peers[2].address = some(sharedAddress) # 3 peers from same IP

    # Manually add to peersInIP to simulate real colocation detection
    gossipSub.peersInIP[sharedAddress] =
      toHashSet([peers[0].peerId, peers[1].peerId, peers[2].peerId])

    # Different IP for other peers
    peers[3].address = some(MultiAddress.init("/ip4/192.168.1.2/tcp/4001").tryGet())
    peers[4].address = some(MultiAddress.init("/ip4/192.168.1.3/tcp/4001").tryGet())

    gossipSub.updateScores()

    # First 3 peers should have colocation penalty
    # over = 3 - 2 = 1, penalty = 1^2 * -0.5 = -0.5
    check peers[0].score == -0.5
    check peers[1].score == -0.5
    check peers[2].score == -0.5

    # Other peers should have no penalty
    check peers[3].score == 0.0
    check peers[4].score == 0.0

  asyncTest "Score decay to zero":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.decayToZero = 0.01
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      firstMessageDeliveriesDecay: 0.1,
      meshMessageDeliveriesDecay: 0.1,
      meshFailurePenaltyDecay: 0.1,
      invalidMessageDeliveriesDecay: 0.1,
    )

    # Set small values that should decay to zero
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        firstMessageDeliveries: 0.05,
        meshMessageDeliveries: 0.08,
        meshFailurePenalty: 0.03,
        invalidMessageDeliveries: 0.06,
      )

    gossipSub.updateScores()

    # All values should be decayed to zero
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      let info = stats[].topicInfos[topic]
      check info.firstMessageDeliveries == 0.0
      check info.meshMessageDeliveries == 0.0
      check info.meshFailurePenalty == 0.0
      check info.invalidMessageDeliveries == 0.0

  asyncTest "Peer stats expiration and eviction":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    let now = Moment.now()

    # Create expired peer stats for disconnected peer
    let expiredPeerId = randomPeerId()
    gossipSub.peerStats[expiredPeerId] = PeerStats(
      expire: now - 1.seconds, # Already expired
      score: -5.0,
    )

    # Create non-expired stats for connected peer
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.expire = now + 10.seconds
      stats.score = 2.0

    check gossipSub.peerStats.len == 2 # Before cleanup: expired + connected peer

    gossipSub.updateScores()

    # Expired peer should be evicted, connected peer should remain
    check gossipSub.peerStats.len == 1
    check expiredPeerId notin gossipSub.peerStats
    check peers[0].peerId in gossipSub.peerStats

  asyncTest "Combined scoring components":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(1, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Set up comprehensive topic parameters
    let now = Moment.now()
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 2.0,
      timeInMeshWeight: 0.1,
      timeInMeshQuantum: 1.seconds,
      timeInMeshCap: 10.0,
      firstMessageDeliveriesWeight: 1.0,
      meshMessageDeliveriesWeight: -0.5,
      meshMessageDeliveriesThreshold: 3.0,
      meshMessageDeliveriesActivation: 1.seconds,
      meshFailurePenaltyWeight: -1.0,
      invalidMessageDeliveriesWeight: -2.0,
    )

    gossipSub.parameters.appSpecificWeight = 0.5
    gossipSub.parameters.behaviourPenaltyWeight = -0.1

    # Set up comprehensive peer state
    let peer = peers[0]
    peer.appScore = 4.0
    peer.behaviourPenalty = 2.0

    gossipSub.withPeerStats(peer.peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 3.seconds, # 3 seconds in mesh
        meshMessageDeliveriesActive: true,
        firstMessageDeliveries: 5.0,
        meshMessageDeliveries: 2.0, # Below threshold
        meshFailurePenalty: 1.0,
        invalidMessageDeliveries: 1.0,
      )

    gossipSub.updateScores()

    # Calculate expected score:
    # Topic score = (timeInMesh + firstMsgDel + meshMsgDelPenalty + meshFailure + invalidMsg) * topicWeight
    # timeInMesh = 3.0 * 0.1 = 0.3
    # firstMsgDel = 5.0 * 1.0 = 5.0
    # meshMsgDelPenalty = (3-2)^2 * -0.5 = 1 * -0.5 = -0.5
    # meshFailure = 1.0 * -1.0 = -1.0
    # invalidMsg = 1^2 * -2.0 = -2.0
    # topicScore = (0.3 + 5.0 - 0.5 - 1.0 - 2.0) * 2.0 = 1.8 * 2.0 = 3.6

    # appScore = 4.0 * 0.5 = 2.0
    # behaviourPenalty = 2^2 * -0.1 = -0.4
    # Total = 3.6 + 2.0 - 0.4 = 5.2

    check abs(peer.score - 5.2) < 0.001 # Allow for floating point precision

  asyncTest "Zero topic weight skips scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Set topic weight to zero
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 0.0,
      firstMessageDeliveriesWeight: 100.0, # High weight but should be ignored
    )

    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 10.0)

    gossipSub.updateScores()

    # Score should be zero since topic weight is zero
    check peers[0].score == 0.0
