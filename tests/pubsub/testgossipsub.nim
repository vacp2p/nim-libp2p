# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import stew/byteutils
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
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

  asyncTest "Peer is punished if message contains invalid sequence number":
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
    let seqno = 1'u64
    var msg = Message.init(peer.peerId, ("bar").toBytes(), topic, some(seqno))
    msg.seqno = ("1").toBytes()

    # When the GossipSub processes the message
    await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    # Then the `invalidMessageDeliveries` counter in the peers stats should be incremented 
    gossipSub.peerStats.withValue(peer.peerId, stats):
      check:
        stats[].topicInfos[topic].invalidMessageDeliveries == 1.0
