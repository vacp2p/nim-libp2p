# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos/rateLimit
import stew/byteutils
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, pubsubpeer]
import ../../libp2p/protocols/pubsub/rpc/[message, protobuf]
import ../../libp2p/muxers/muxer
import ../helpers

suite "GossipSub":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "onNewPeer - sets peer stats and budgets and disconnects if bad score":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      peerStats = PeerStats(
        score: gossipSub.parameters.graylistThreshold - 1.0,
        appScore: 10.0,
        behaviourPenalty: 5.0,
      )
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And existing peer stats are set
    gossipSub.peerStats[peer.peerId] = peerStats

    # And the peer is connected
    gossipSub.switch.connManager.storeMuxer(Muxer(connection: conns[0]))
    check:
      gossipSub.switch.isConnected(peer.peerId)

    # When onNewPeer is called
    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.onNewPeer(peer)

    # Then peer stats are updated
    check:
      peer.score == peerStats.score
      peer.appScore == peerStats.appScore
      peer.behaviourPenalty == peerStats.behaviourPenalty

    # And peer budgets are set to default values
    check:
      peer.iHaveBudget == IHavePeerBudget
      peer.pingBudget == PingsPeerBudget

    # And peer is disconnected because score < graylistThreshold
    checkUntilTimeout:
      not gossipSub.switch.isConnected(peer.peerId)

  asyncTest "onPubSubPeerEvent - StreamClosed removes peer from mesh and fanout":
    # Given a GossipSub instance with one peer in both mesh and fanout
    let
      (gossipSub, conns, peers) =
        setupGossipSubWithPeers(1, topic, populateMesh = true, populateFanout = true)
      peer = peers[0]
      event = PubSubPeerEvent(kind: PubSubPeerEventKind.StreamClosed)
    defer:
      await teardownGossipSub(gossipSub, conns)

    check:
      gossipSub.mesh.hasPeerId(topic, peer.peerId)
      gossipSub.fanout.hasPeerId(topic, peer.peerId)

    # When StreamClosed event is handled
    gossipSub.onPubSubPeerEvent(peer, event)

    # Then peer is removed from both mesh and fanout
    check:
      not gossipSub.mesh.hasPeerId(topic, peer.peerId)
      not gossipSub.fanout.hasPeerId(topic, peer.peerId)

  asyncTest "onPubSubPeerEvent - DisconnectionRequested disconnects peer":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(
        1, topic, populateGossipsub = true, populateMesh = true, populateFanout = true
      )
      peer = peers[0]
      event = PubSubPeerEvent(kind: PubSubPeerEventKind.DisconnectionRequested)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And the peer is connected
    gossipSub.switch.connManager.storeMuxer(Muxer(connection: conns[0]))
    check:
      gossipSub.switch.isConnected(peer.peerId)
      gossipSub.mesh.hasPeerId(topic, peer.peerId)
      gossipSub.fanout.hasPeerId(topic, peer.peerId)
      gossipSub.gossipsub.hasPeerId(topic, peer.peerId)

    # When DisconnectionRequested event is handled
    gossipSub.onPubSubPeerEvent(peer, event)

    # Then peer should be disconnected
    checkUntilTimeout:
      not gossipSub.switch.isConnected(peer.peerId)
      not gossipSub.mesh.hasPeerId(topic, peer.peerId)
      not gossipSub.fanout.hasPeerId(topic, peer.peerId)
      not gossipSub.gossipsub.hasPeerId(topic, peer.peerId)

  asyncTest "unsubscribePeer - handles nil peer gracefully":
    # Given a GossipSub instance
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(0, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And a non-existent peer ID
    let nonExistentPeerId = randomPeerId()

    # When unsubscribePeer is called with non-existent peer
    gossipSub.unsubscribePeer(nonExistentPeerId)

    # Then no errors occur (method returns early for nil peers)
    check:
      true

  asyncTest "unsubscribePeer - removes peer from mesh, gossipsub, fanout and subscribedDirectPeers":
    # Given a GossipSub instance with one peer in mesh
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(
        1, topic, populateGossipsub = true, populateMesh = true, populateFanout = true
      )
      peer = peers[0]
      peerId = peer.peerId
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer is configured as a direct peer
    gossipSub.parameters.directPeers[peerId] = @[]
    discard gossipSub.subscribedDirectPeers.addPeer(topic, peer)

    check:
      gossipSub.mesh.hasPeerId(topic, peerId)
      gossipSub.gossipsub.hasPeerId(topic, peerId)
      gossipSub.fanout.hasPeerId(topic, peerId)
      gossipSub.subscribedDirectPeers.hasPeerId(topic, peerId)

    # When unsubscribePeer is called
    gossipSub.unsubscribePeer(peerId)

    # Then peer is removed from mesh
    check:
      not gossipSub.mesh.hasPeerId(topic, peerId)
      not gossipSub.gossipsub.hasPeerId(topic, peerId)
      not gossipSub.fanout.hasPeerId(topic, peerId)
      not gossipSub.subscribedDirectPeers.hasPeerId(topic, peerId)

  asyncTest "unsubscribePeer - resets firstMessageDeliveries in peerStats":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      peerId = peer.peerId
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer stats with firstMessageDeliveries set
    gossipSub.peerStats[peerId] = PeerStats()
    gossipSub.peerStats[peerId].topicInfos[topic] =
      TopicInfo(firstMessageDeliveries: 5.0)
    check:
      gossipSub.peerStats[peerId].topicInfos[topic].firstMessageDeliveries == 5.0

    # When unsubscribePeer is called
    gossipSub.unsubscribePeer(peerId)

    # Then firstMessageDeliveries is reset to 0
    gossipSub.peerStats.withValue(peerId, stats):
      check:
        stats[].topicInfos[topic].firstMessageDeliveries == 0.0

  asyncTest "unsubscribePeer - removes peer from peersInIP collection":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      peerId = peer.peerId
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer has an address and is in peersInIP
    let testAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
    peer.address = some(testAddress)
    gossipSub.peersInIP[testAddress] = initHashSet[PeerId]()
    gossipSub.peersInIP[testAddress].incl(peerId)

    # And verify peer is initially in peersInIP
    check:
      peerId in gossipSub.peersInIP[testAddress]

    # When unsubscribePeer is called
    gossipSub.unsubscribePeer(peerId)

    # Then peer is removed from peersInIP
    check:
      testAddress notin gossipSub.peersInIP

  asyncTest "handleSubscribe via rpcHandler - subscribe and unsubscribe with direct peer":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And the peer is configured as a direct peer
    gossipSub.parameters.directPeers[peer.peerId] = @[]

    # When a subscribe message is sent via RPC handler
    await gossipSub.rpcHandler(
      peer, encodeRpcMsg(RPCMsg.withSubs(@[topic], true), false)
    )

    # Then the peer is added to gossipsub for the topic
    # And the peer is added to subscribedDirectPeers
    check:
      gossipSub.gossipsub.hasPeer(topic, peer)
      gossipSub.subscribedDirectPeers.hasPeer(topic, peer)

    # When Peer is added to the mesh and fanout
    discard gossipSub.mesh.addPeer(topic, peer)
    discard gossipSub.fanout.addPeer(topic, peer)

    # And an unsubscribe message is sent via RPC handler
    await gossipSub.rpcHandler(
      peer, encodeRpcMsg(RPCMsg.withSubs(@[topic], false), false)
    )

    # Then the peer is removed from gossipsub, mesh and fanout
    # And the peer is removed from subscribedDirectPeers
    check:
      not gossipSub.gossipsub.hasPeer(topic, peer)
      not gossipSub.mesh.hasPeer(topic, peer)
      not gossipSub.fanout.hasPeer(topic, peer)
      not gossipSub.subscribedDirectPeers.hasPeer(topic, peer)

  asyncTest "handleSubscribe via rpcHandler - subscribe unknown peer":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer is not in gossipSub.peers
    let nonExistentPeerId = randomPeerId()
    peer.peerId = nonExistentPeerId # override PeerId

    # When a subscribe message is sent via RPC handler
    await gossipSub.rpcHandler(
      peer, encodeRpcMsg(RPCMsg.withSubs(@[topic], true), false)
    )

    # Then the peer is ignored
    check:
      not gossipSub.gossipsub.hasPeer(topic, peer)

  asyncTest "subscribe/unsubscribeAll":
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # test via dynamic dispatch
    gossipSub.PubSub.subscribe(topic, voidTopicHandler)

    check:
      gossipSub.topics.contains(topic)
      gossipSub.gossipsub[topic].len() > 0
      gossipSub.mesh[topic].len() > 0

    # test via dynamic dispatch
    gossipSub.PubSub.unsubscribeAll(topic)

    check:
      topic notin gossipSub.topics # not in local topics
      topic notin gossipSub.mesh # not in mesh
      topic in gossipSub.gossipsub # but still in gossipsub table (for fanning out)

  asyncTest "Drop messages of topics without subscription":
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      let peer = peers[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    check gossipSub.mcache.msgs.len == 0

  asyncTest "subscription limits":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.topicsHigh = 10

    var tooManyTopics: seq[string]
    for i in 0 .. gossipSub.topicsHigh + 10:
      tooManyTopics &= topic & $i
    let lotOfSubs = RPCMsg.withSubs(tooManyTopics, true)

    let conn = TestBufferStream.new(noop)
    let peerId = randomPeerId()
    conn.peerId = peerId
    let peer = gossipSub.getPubSubPeer(peerId)

    await gossipSub.rpcHandler(peer, encodeRpcMsg(lotOfSubs, false))

    check:
      gossipSub.gossipsub.len == gossipSub.topicsHigh
      peer.behaviourPenalty > 0.0

    await conn.close()

  asyncTest "invalid message bytes":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let peerId = randomPeerId()
    let peer = gossipSub.getPubSubPeer(peerId)

    expect(CatchableError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

  asyncTest "Peer is disconnected and rate limit is hit when overhead rate limit is exceeded":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      rateLimitHits = currentRateLimitHits("unknown")
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And signature verification disabled to avoid message being dropped
    gossipSub.verifySignature = false

    # And peer disconnection is enabled when rate limit is exceeded
    gossipSub.parameters.disconnectPeerAboveRateLimit = true

    # And low overheadRateLimit is set
    const
      bytes = 1
      interval = 1.millis
      overheadRateLimit = Opt.some((bytes, interval))

    gossipSub.parameters.overheadRateLimit = overheadRateLimit
    peer.overheadRateLimitOpt = Opt.some(TokenBucket.new(bytes, interval))

    # And a message is created that will exceed the overhead rate limit
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(1'u64))

    # When the GossipSub processes the message
    # Then it throws an exception due to peer disconnection
    expect(PeerRateLimitError):
      await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # And the rate limit hit counter is incremented
    check:
      currentRateLimitHits("unknown") == rateLimitHits + 1

  asyncTest "Peer is disconnected and rate limit is hit when overhead rate limit is exceeded when decodeRpcMsg fails":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      rateLimitHits = currentRateLimitHits("unknown")
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer disconnection is enabled when rate limit is exceeded
    gossipSub.parameters.disconnectPeerAboveRateLimit = true

    # And low overheadRateLimit is set
    const
      bytes = 1
      interval = 1.millis
      overheadRateLimit = Opt.some((bytes, interval))

    gossipSub.parameters.overheadRateLimit = overheadRateLimit
    peer.overheadRateLimitOpt = Opt.some(TokenBucket.new(bytes, interval))

    # When invalid RPC data is sent that fails to decode
    expect(PeerRateLimitError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

    # And the rate limit hit counter is incremented
    check:
      currentRateLimitHits("unknown") == rateLimitHits + 1

  asyncTest "Peer is punished and rate limit is hit when overhead rate limit is exceeded when decodeRpcMsg fails":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
      rateLimitHits = currentRateLimitHits("unknown")
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And peer disconnection is disabled when rate limit is exceeded to not raise PeerRateLimitError
    gossipSub.parameters.disconnectPeerAboveRateLimit = false

    # And low overheadRateLimit is set
    const
      bytes = 1
      interval = 1.millis
      overheadRateLimit = Opt.some((bytes, interval))

    gossipSub.parameters.overheadRateLimit = overheadRateLimit
    peer.overheadRateLimitOpt = Opt.some(TokenBucket.new(bytes, interval))

    # And initial behavior penalty is zero
    check:
      peer.behaviourPenalty == 0.0

    # When invalid RPC data is sent that fails to decode
    expect(PeerMessageDecodeError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

    # And the rate limit hit counter is incremented
    check:
      currentRateLimitHits("unknown") == rateLimitHits + 1
      peer.behaviourPenalty == 0.1

  asyncTest "Peer is punished when decodeRpcMsg fails":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And initial behavior penalty is zero
    check:
      peer.behaviourPenalty == 0.0

    # When invalid RPC data is sent that fails to decode
    expect(PeerMessageDecodeError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

    # Then the peer is penalized with behavior penalty
    check:
      peer.behaviourPenalty == 0.1

  asyncTest "Peer is punished when message contains invalid sequence number":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And signature verification disabled to avoid message being dropped
    gossipSub.verifySignature = false

    # And a message is created with invalid sequence number
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(1'u64))
    msg.seqno = ("1").toBytes()

    # When the GossipSub processes the message
    await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # Then the peer's invalidMessageDeliveries counter is incremented 
    gossipSub.peerStats.withValue(peer.peerId, stats):
      check:
        stats[].topicInfos[topic].invalidMessageDeliveries == 1.0

  asyncTest "Peer is punished when message id generation fails":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And signature verification disabled to avoid message being dropped
    gossipSub.verifySignature = false

    # And a custom msgIdProvider is set that always returns an error
    func customMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      err(ValidationResult.Reject)
    gossipSub.msgIdProvider = customMsgIdProvider

    # And a message is created
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(1'u64))

    # When the GossipSub processes the message
    await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # Then the peer's invalidMessageDeliveries counter is incremented
    gossipSub.peerStats.withValue(peer.peerId, stats):
      check:
        stats[].topicInfos[topic].invalidMessageDeliveries == 1.0

  asyncTest "Peer is punished when signature verification fails":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And signature verification enabled
    gossipSub.verifySignature = true

    # And a message without signature is created
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(1'u64))

    # When the GossipSub processes the message
    await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # Then the peer's invalidMessageDeliveries counter is incremented
    gossipSub.peerStats.withValue(peer.peerId, stats):
      check:
        stats[].topicInfos[topic].invalidMessageDeliveries == 1.0

  asyncTest "Peer is punished when message validation is rejected":
    # Given a GossipSub instance with one peer
    let
      (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
      peer = peers[0]
    defer:
      await teardownGossipSub(gossipSub, conns)

    # And signature verification disabled to avoid message being dropped earlier
    gossipSub.verifySignature = false

    # And a custom validator that always rejects messages
    proc rejectingValidator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      return ValidationResult.Reject

    # Register the rejecting validator for the topic
    gossipSub.addValidator(topic, rejectingValidator)

    # And a message is created
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(1'u64))

    # When the GossipSub processes the message
    await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # Then the peer's invalidMessageDeliveries counter is incremented
    gossipSub.peerStats.withValue(peer.peerId, stats):
      check:
        stats[].topicInfos[topic].invalidMessageDeliveries == 1.0
