# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
import ../helpers

suite "GossipSub":
  teardown:
    checkTrackers()

  asyncTest "subscribe/unsubscribeAll":
    let topic = "foobar"
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
    let topic = "foobar"
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
      tooManyTopics &= "topic" & $i
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
    const topic = "foobar"
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

  asyncTest "Peer is punished when message contains invalid sequence number":
    # Given a GossipSub instance with one peer
    const topic = "foobar"
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
    const topic = "foobar"
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
    const topic = "foobar"
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
    const topic = "foobar"
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
