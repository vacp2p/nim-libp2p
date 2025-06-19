{.used.}

import chronos
import math
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

  asyncTest "Time in mesh scoring (P1)":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(3, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0, # No multiplication factor
      timeInMeshWeight: 1.0, # Weight = 1.0
      timeInMeshQuantum: 1.seconds, # 1 second quantum
      timeInMeshCap: 10.0, # Cap at 10.0
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
        graftTime: now - 12.seconds, # 12 seconds in mesh (should be capped at 10)
      )

    gossipSub.withPeerStats(peers[2].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: false # Not in mesh
      )

    gossipSub.updateScores()

    # Score calculation breakdown:
    # P1 formula: min(meshTime / timeInMeshQuantum, timeInMeshCap) * timeInMeshWeight * topicWeight

    check:
      # Peer 0: min(2.0s / 1s, 10.0) * 1.0 * 1.0 = 2.0
      round(peers[0].score, 1) == 2.0
      # Peer 1: min(12.0s / 1s, 10.0) * 1.0 * 1.0 = 10.0 (capped at timeInMeshCap)
      round(peers[1].score, 1) == 10.0
      # Peer 2: not in mesh, score should be 0
      round(peers[2].score, 1) == 0.0

  asyncTest "First message deliveries scoring (P2)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      firstMessageDeliveriesWeight: 2.0,
      firstMessageDeliveriesDecay: 0.5,
    )

    # Set different first message delivery counts
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 4.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 0.0)

    gossipSub.withPeerStats(peers[2].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(firstMessageDeliveries: 2.0)

    gossipSub.updateScores()

    # Check scores: firstMessageDeliveries * weight
    check:
      round(peers[0].score, 1) == 8.0 # 4.0 * 2.0
      round(peers[1].score, 1) == 0.0 # 0.0 * 2.0
      round(peers[2].score, 1) == 4.0 # 2.0 * 2.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check:
        round(stats[].topicInfos[topic].firstMessageDeliveries, 1) == 2.0 # 4.0 * 0.5

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
      meshMessageDeliveriesThreshold: 4.0,
      meshMessageDeliveriesActivation: 1.seconds,
      meshMessageDeliveriesDecay: 0.5,
    )

    # Set up peers with different mesh message delivery counts
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 2.seconds,
        meshMessageDeliveries: 2.0, # Below threshold
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

    check:
      # Peer 0: deficit = 4 - 2 = 2, penalty = 2^2 * -1 = -4
      round(peers[0].score, 1) == -4.0
      # Peer 1: above threshold, no penalty
      round(peers[1].score, 1) == 0.0
      # Peer 2: not active yet, no penalty
      round(peers[2].score, 1) == 0.0

  asyncTest "Mesh failure penalty scoring (P3b)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(2, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0, meshFailurePenaltyWeight: -2.0, meshFailurePenaltyDecay: 0.5
    )

    # Set mesh failure penalty
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(meshFailurePenalty: 2.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(meshFailurePenalty: 0.0)

    gossipSub.updateScores()

    # Check penalty application
    check:
      round(peers[0].score, 1) == -4.0 # 2.0 * -2.0
      round(peers[1].score, 1) == 0.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check:
        round(stats[].topicInfos[topic].meshFailurePenalty, 1) == 1.0 # 2.0 * 0.5

  asyncTest "Invalid message deliveries scoring (P4)":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(2, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 1.0,
      invalidMessageDeliveriesWeight: -4.0,
      invalidMessageDeliveriesDecay: 0.5,
    )

    # Set invalid message deliveries
    gossipSub.withPeerStats(peers[0].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(invalidMessageDeliveries: 2.0)

    gossipSub.withPeerStats(peers[1].peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(invalidMessageDeliveries: 0.0)

    gossipSub.updateScores()

    # Check penalty: 2^2 * -4 = -16
    check:
      round(peers[0].score, 1) == -16.0
      round(peers[1].score, 1) == 0.0

    # Check decay was applied
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      check:
        round(stats[].topicInfos[topic].invalidMessageDeliveries, 1) == 1.0 # 2.0 * 0.5

  asyncTest "App-specific scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.appSpecificWeight = 0.5

    # Set different app scores
    peers[0].appScore = 8.0
    peers[1].appScore = -6.0
    peers[2].appScore = 0.0

    gossipSub.updateScores()

    check:
      round(peers[0].score, 1) == 4.0 # 8.0 * 0.5
      round(peers[1].score, 1) == -3.0 # -6.0 * 0.5
      round(peers[2].score, 1) == 0.0 # 0.0 * 0.5

  asyncTest "Behaviour penalty scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(3, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.behaviourPenaltyWeight = -0.25
    gossipSub.parameters.behaviourPenaltyDecay = 0.5

    # Set different behaviour penalties
    peers[0].behaviourPenalty = 4.0
    peers[1].behaviourPenalty = 2.0
    peers[2].behaviourPenalty = 0.0

    gossipSub.updateScores()

    # Check penalty: penalty^2 * weight
    check:
      round(peers[0].score, 1) == -4.0 # 4^2 * -0.25 = -4.0
      round(peers[1].score, 1) == -1.0 # 2^2 * -0.25 = -1.0
      round(peers[2].score, 1) == 0.0 # 0^2 * -0.25 = 0.0

    # Check decay was applied
    check:
      round(peers[0].behaviourPenalty, 1) == 2.0 # 4.0 * 0.5
      round(peers[1].behaviourPenalty, 1) == 1.0 # 2.0 * 0.5
      round(peers[2].behaviourPenalty, 1) == 0.0

  asyncTest "Colocation factor scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(5, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.ipColocationFactorWeight = -1.0
    gossipSub.parameters.ipColocationFactorThreshold = 2.0

    # Simulate peers from same IP
    let sharedAddress = MultiAddress.init("/ip4/192.168.1.1/tcp/4001").tryGet()
    peers[0].address = some(sharedAddress)
    peers[1].address = some(sharedAddress)
    peers[2].address = some(sharedAddress) # 3 peers from same IP

    # Add to peersInIP to simulate colocation detection
    gossipSub.peersInIP[sharedAddress] =
      toHashSet([peers[0].peerId, peers[1].peerId, peers[2].peerId])

    # Different IP for other peers
    peers[3].address = some(MultiAddress.init("/ip4/192.168.1.2/tcp/4001").tryGet())
    peers[4].address = some(MultiAddress.init("/ip4/192.168.1.3/tcp/4001").tryGet())

    gossipSub.updateScores()

    check:
      # First 3 peers should have colocation penalty
      # over = 3 - 2 = 1, penalty = 1^2 * -1.0 = -1.0
      round(peers[0].score, 1) == -1.0
      round(peers[1].score, 1) == -1.0
      round(peers[2].score, 1) == -1.0
      # Other peers should have no penalty
      round(peers[3].score, 1) == 0.0
      round(peers[4].score, 1) == 0.0

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
        firstMessageDeliveries: 0.02,
        meshMessageDeliveries: 0.04,
        meshFailurePenalty: 0.06,
        invalidMessageDeliveries: 0.08,
      )

    gossipSub.updateScores()

    # All values should be decayed to zero
    gossipSub.peerStats.withValue(peers[0].peerId, stats):
      let info = stats[].topicInfos[topic]
      check:
        round(info.firstMessageDeliveries, 1) == 0.0
        round(info.meshMessageDeliveries, 1) == 0.0
        round(info.meshFailurePenalty, 1) == 0.0
        round(info.invalidMessageDeliveries, 1) == 0.0

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

    check:
      gossipSub.peerStats.len == 2 # Before cleanup: expired + connected peer

    gossipSub.updateScores()

    # Expired peer should be evicted, connected peer should remain
    check:
      gossipSub.peerStats.len == 1
      expiredPeerId notin gossipSub.peerStats
      peers[0].peerId in gossipSub.peerStats

  asyncTest "Combined scoring":
    const topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(1, topic, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Set up all topic parameters
    let now = Moment.now()
    gossipSub.topicParams[topic] = TopicParams(
      topicWeight: 2.0,
      timeInMeshWeight: 0.25, # P1
      timeInMeshQuantum: 1.seconds,
      timeInMeshCap: 10.0,
      firstMessageDeliveriesWeight: 1.0, # P2
      meshMessageDeliveriesWeight: -1.0, # P3
      meshMessageDeliveriesThreshold: 4.0,
      meshMessageDeliveriesActivation: 1.seconds,
      meshFailurePenaltyWeight: -2.0, # P3b
      invalidMessageDeliveriesWeight: -1.0, # P4
    )

    gossipSub.parameters.appSpecificWeight = 0.5
    gossipSub.parameters.behaviourPenaltyWeight = -0.25

    # Set up peer state
    let peer = peers[0]
    peer.appScore = 6.0
    peer.behaviourPenalty = 2.0

    gossipSub.withPeerStats(peer.peerId) do(stats: var PeerStats):
      stats.topicInfos[topic] = TopicInfo(
        inMesh: true,
        graftTime: now - 4.seconds, # 4 seconds in mesh
        meshMessageDeliveriesActive: true,
        firstMessageDeliveries: 3.0, # P2 component
        meshMessageDeliveries: 2.0, # P3 component (below threshold)
        meshFailurePenalty: 1.0, # P3b component
        invalidMessageDeliveries: 2.0, # P4 component
      )

    gossipSub.updateScores()

    # Calculate expected score step by step:
    # 
    # P1 (time in mesh): meshTime / timeInMeshQuantum * timeInMeshWeight
    #                   = 4.0s / 1s * 0.25 = 1.0
    # 
    # P2 (first message deliveries): firstMessageDeliveries * firstMessageDeliveriesWeight
    #                                = 3.0 * 1.0 = 3.0
    # 
    # P3 (mesh message deliveries): deficit = max(0, threshold - deliveries)
    #                               deficit = max(0, 4.0 - 2.0) = 2.0
    #                               penalty = deficit^2 * weight = 2.0^2 * -1.0 = -4.0
    # 
    # P3b (mesh failure penalty): meshFailurePenalty * meshFailurePenaltyWeight
    #                             = 1.0 * -2.0 = -2.0
    # 
    # P4 (invalid message deliveries): invalidMessageDeliveries^2 * invalidMessageDeliveriesWeight
    #                                  = 2.0^2 * -1.0 = -4.0
    # 
    # Topic score = (P1 + P2 + P3 + P3b + P4) * topicWeight
    #             = (1.0 + 3.0 + (-4.0) + (-2.0) + (-4.0)) * 2.0
    #             = (1.0 + 3.0 - 4.0 - 2.0 - 4.0) * 2.0
    #             = -6.0 * 2.0 = -12.0
    # 
    # App score = appScore * appSpecificWeight = 6.0 * 0.5 = 3.0
    # 
    # Behaviour penalty = behaviourPenalty^2 * behaviourPenaltyWeight
    #                   = 2.0^2 * -0.25 = 4.0 * -0.25 = -1.0
    # 
    # Final score = topicScore + appScore + behaviourPenalty
    #             = -12.0 + 3.0 + (-1.0) = -10.0

    check:
      round(peer.score, 1) == -10.0

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
    check:
      round(peers[0].score, 1) == 0.0
