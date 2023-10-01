# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[options, deques, sequtils, enumerate, algorithm]
import stew/byteutils
import ../../libp2p/builders
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream
import ../../libp2p/protocols/pubsub/[pubsub, gossipsub, mcache, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message, messages]
import ../../libp2p/switch
import ../../libp2p/muxers/muxer
import ../../libp2p/protocols/pubsub/rpc/protobuf
import utils

import ../helpers

proc noop(data: seq[byte]) {.async, gcsafe.} = discard

const MsgIdSuccess = "msg id gen success"

suite "GossipSub internal":
  teardown:
    checkTrackers()

  asyncTest "subscribe/unsubscribeAll":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(topic: string, data: seq[byte]): Future[void] {.gcsafe.} =
      discard

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    # test via dynamic dispatch
    gossipSub.PubSub.subscribe(topic, handler)

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

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "topic params":
    let params = TopicParams.init()
    params.validateParameters().tryGet()

  asyncTest "`rebalanceMesh` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh - bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var scoreLow = -11'f64
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      peer.score = scoreLow
      gossipSub.gossipsub[topic].incl(peer)
      scoreLow += 1.0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # low score peers should not be in mesh, that's why the count must be 4
    check gossipSub.mesh[topic].len == 4
    for peer in gossipSub.mesh[topic]:
      check peer.score >= 0.0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`rebalanceMesh` Degree Hi":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d + gossipSub.parameters.dScore

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`replenishFanout` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      var peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.gossipsub[topic].len == 15
    gossipSub.replenishFanout(topic)
    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` drop expired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic] = Moment.fromNow(1.millis)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0..<6:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.fanout[topic].incl(peer)

    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic notin gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` leave unexpired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic1 = "foobar1"
    let topic2 = "foobar2"
    gossipSub.topicParams[topic1] = TopicParams.init()
    gossipSub.topicParams[topic2] = TopicParams.init()
    gossipSub.fanout[topic1] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic2] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic1] = Moment.fromNow(1.millis)
    gossipSub.lastFanoutPubSub[topic2] = Moment.fromNow(1.minutes)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0..<6:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.fanout[topic1].incl(peer)
      gossipSub.fanout[topic2].incl(peer)

    check gossipSub.fanout[topic1].len == gossipSub.parameters.d
    check gossipSub.fanout[topic2].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic1 notin gossipSub.fanout
    check topic2 in gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should gather up to degree D non intersecting peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()

    # generate mesh and fanout peers
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d
    for p in peers.keys:
      check not gossipSub.fanout.hasPeerId(topic, p.peerId)
      check not gossipSub.mesh.hasPeerId(topic, p.peerId)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "Drop messages of topics without subscription":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      inc seqno
      let msg = Message.init(peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    check gossipSub.mcache.msgs.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "Disconnect bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0
    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      peer.handler = handler
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      gossipSub.gossipsub.mgetOrPut(topic, initHashSet[PubSubPeer]()).incl(peer)
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "subscription limits":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.topicsHigh = 10

    var tooManyTopics: seq[string]
    for i in 0..gossipSub.topicsHigh + 10:
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
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh fail due to backoff":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)
      gossipSub.backingOff
        .mgetOrPut(topic, initTable[PeerId, Moment]())
        .add(peerId, Moment.now() + 1.hours)
      let prunes = gossipSub.handleGraft(peer, @[ControlGraft(topicID: topic)])
      # there must be a control prune due to violation of backoff
      check prunes.len != 0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # expect 0 since they are all backing off
    check gossipSub.mesh[topic].len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh fail due to backoff - remote":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len != 0

    for i in 0..<15:
      let peerId = conns[i].peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.handlePrune(peer, @[ControlPrune(
        topicID: topic,
        peers: @[],
        backoff: gossipSub.parameters.pruneBackoff.seconds.uint64
      )])

    # expect topic cleaned up since they are all pruned
    check topic notin gossipSub.mesh

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh Degree Hi - audit scenario":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.parameters.dScore = 4
    gossipSub.parameters.d = 6
    gossipSub.parameters.dOut = 3
    gossipSub.parameters.dHigh = 12
    gossipSub.parameters.dLow = 4

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<6:
      let conn = TestBufferStream.new(noop)
      conn.transportDir = Direction.In
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.score = 40.0
      peer.sendConn = conn
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    for i in 0..<7:
      let conn = TestBufferStream.new(noop)
      conn.transportDir = Direction.Out
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.score = 10.0
      peer.sendConn = conn
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 13
    gossipSub.rebalanceMesh(topic)
    # ensure we are above dlow
    check gossipSub.mesh[topic].len > gossipSub.parameters.dLow
    var outbound = 0
    for peer in gossipSub.mesh[topic]:
      if peer.sendConn.transportDir == Direction.Out:
        inc outbound
    # ensure we give priority and keep at least dOut outbound peers
    check outbound >= gossipSub.parameters.dOut

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "handleIHave/Iwant tests":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
      check false
    proc handler2(topic: string, data: seq[byte]) {.async.} = discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.subscribe(topic, handler2)

    for i in 0..<30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    block:
      # should ignore no budget peer
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      let msg = ControlIHave(
        topicID: topic,
        messageIDs: @[id, id, id]
      )
      peer.iHaveBudget = 0
      let iwants = gossipSub.handleIHave(peer, @[msg])
      check: iwants.messageIds.len == 0

    block:
      # given duplicate ihave should generate only one iwant
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      let msg = ControlIHave(
        topicID: topic,
        messageIDs: @[id, id, id]
      )
      let iwants = gossipSub.handleIHave(peer, @[msg])
      check: iwants.messageIds.len == 1

    block:
      # given duplicate iwant should generate only one message
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      let msg = ControlIWant(
        messageIDs: @[id, id, id]
      )
      let genmsg = gossipSub.handleIWant(peer, @[msg])
      check: genmsg.len == 1

    check gossipSub.mcache.msgs.len == 1

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "two IHAVEs should generate only one IWANT":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    var iwantCount = 0

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} =
     check false

    proc handler2(topic: string, data: seq[byte]) {.async.} = discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.subscribe(topic, handler2)

    # Setup two connections and two peers
    var ihaveMessageId: string
    var firstPeer: PubSubPeer
    let seqno = @[0'u8, 1, 2, 3]
    for i in 0..<2:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      if isNil(firstPeer):
        firstPeer = peer
        ihaveMessageId = byteutils.toHex(seqno) & $firstPeer.peerId
      peer.handler = handler

      # Simulate that each peer sends an IHAVE message to our node
      let msg = ControlIHave(
        topicID: topic,
        messageIDs: @[ihaveMessageId.toBytes()]
      )
      let iwants =  gossipSub.handleIHave(peer, @[msg])
      if iwants.messageIds.len > 0:
        iwantCount += 1

    # Verify that our node responds with only one IWANT message
    check: iwantCount == 1
    check: gossipSub.outstandingIWANTs.contains(ihaveMessageId.toBytes())

    # Simulate that our node receives the RPCMsg in response to the IWANT
    let actualMessageData = "Hello, World!".toBytes
    let rpcMsg = RPCMsg(
      messages: @[Message(
        fromPeer: firstPeer.peerId,
        seqno: seqno,
        data: actualMessageData
      )]
    )
    await gossipSub.rpcHandler(firstPeer, encodeRpcMsg(rpcMsg, false))

    check: not gossipSub.outstandingIWANTs.contains(ihaveMessageId.toBytes())

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "handle unanswered IWANT messages":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.parameters.heartbeatInterval = 50.milliseconds
    gossipSub.parameters.iwantTimeout = 10.milliseconds
    await gossipSub.start()

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async.} = discard
    proc handler2(topic: string, data: seq[byte]) {.async.} = discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.subscribe(topic, handler2)

    # Setup a connection and a peer
    let conn = TestBufferStream.new(noop)
    conns &= conn
    let peerId = randomPeerId()
    conn.peerId = peerId
    let peer = gossipSub.getPubSubPeer(peerId)
    peer.handler = handler

    # Simulate that the peer sends an IHAVE message to our node
    let ihaveMessageId = @[0'u8, 1, 2, 3]
    let ihaveMsg = ControlIHave(
      topicID: topic,
      messageIDs: @[ihaveMessageId]
    )
    discard gossipSub.handleIHave(peer, @[ihaveMsg])

    check: gossipSub.outstandingIWANTs.contains(ihaveMessageId)
    check: peer.behaviourPenalty == 0.0

    await sleepAsync(60.milliseconds)

    check: not gossipSub.outstandingIWANTs.contains(ihaveMessageId)
    check: peer.behaviourPenalty == 0.1

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  proc setupTest(): Future[tuple[gossip0: GossipSub, gossip1: GossipSub, receivedMessages: ref HashSet[seq[byte]]]] {.async.} =
    let
      nodes = generateNodes(2, gossip = true, verifySignature = false)
    discard await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start()
      )

    await nodes[1].switch.connect(nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs)

    var receivedMessages = new(HashSet[seq[byte]])

    proc handlerA(topic: string, data: seq[byte]) {.async, gcsafe.} =
      receivedMessages[].incl(data)

    proc handlerB(topic: string, data: seq[byte]) {.async, gcsafe.} =
      discard

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip0: GossipSub = GossipSub(nodes[0])
    var gossip1: GossipSub = GossipSub(nodes[1])

    return (gossip0, gossip1, receivedMessages)

  proc teardownTest(gossip0: GossipSub, gossip1: GossipSub) {.async.} =
    await allFuturesThrowing(
      gossip0.switch.stop(),
      gossip1.switch.stop()
    )

  proc createMessages(gossip0: GossipSub, gossip1: GossipSub, size1: int, size2: int): tuple[iwantMessageIds: seq[MessageId], sentMessages: HashSet[seq[byte]]] =
    var iwantMessageIds = newSeq[MessageId]()
    var sentMessages = initHashSet[seq[byte]]()

    for i, size in enumerate([size1, size2]):
      let data = newSeqWith[byte](size, i.byte)
      sentMessages.incl(data)

      let msg = Message.init(gossip1.peerInfo.peerId, data, "foobar", some(uint64(i + 1)))
      let iwantMessageId = gossip1.msgIdProvider(msg).expect(MsgIdSuccess)
      iwantMessageIds.add(iwantMessageId)
      gossip1.mcache.put(iwantMessageId, msg)

      let peer = gossip1.peers[(gossip0.peerInfo.peerId)]
      peer.sentIHaves[^1].incl(iwantMessageId)

    return (iwantMessageIds, sentMessages)

  asyncTest "e2e - Split IWANT replies when individual messages are below maxSize but combined exceed maxSize":
    # This test checks if two messages, each below the maxSize, are correctly split when their combined size exceeds maxSize.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()

    let messageSize = gossip1.maxMessageSize div 2 + 1
    let (iwantMessageIds, sentMessages) = createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(gossip1.mesh["foobar"], RPCMsg(control: some(ControlMessage(
      ihave: @[ControlIHave(topicId: "foobar", messageIds: iwantMessageIds)]
    ))))

    checkExpiring: receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Discard IWANT replies when both messages individually exceed maxSize":
    # This test checks if two messages, each exceeding the maxSize, are discarded and not sent.
    # Expected: No messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()

    let messageSize = gossip1.maxMessageSize + 10
    let (bigIWantMessageIds, sentMessages) = createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(gossip1.mesh["foobar"], RPCMsg(control: some(ControlMessage(
      ihave: @[ControlIHave(topicId: "foobar", messageIds: bigIWantMessageIds)]
    ))))

    await sleepAsync(300.milliseconds)
    checkExpiring: receivedMessages[].len == 0

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Process IWANT replies when both messages are below maxSize":
    # This test checks if two messages, both below the maxSize, are correctly processed and sent.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let size1 = gossip1.maxMessageSize div 2
    let size2 = gossip1.maxMessageSize div 3
    let (bigIWantMessageIds, sentMessages) = createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(gossip1.mesh["foobar"], RPCMsg(control: some(ControlMessage(
      ihave: @[ControlIHave(topicId: "foobar", messageIds: bigIWantMessageIds)]
    ))))

    checkExpiring: receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Split IWANT replies when one message is below maxSize and the other exceeds maxSize":
    # This test checks if, when given two messages where one is below maxSize and the other exceeds it, only the smaller message is processed and sent.
    # Expected: Only the smaller message should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let maxSize = gossip1.maxMessageSize
    let size1 = maxSize div 2
    let size2 = maxSize + 10
    let (bigIWantMessageIds, sentMessages) = createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(gossip1.mesh["foobar"], RPCMsg(control: some(ControlMessage(
      ihave: @[ControlIHave(topicId: "foobar", messageIds: bigIWantMessageIds)]
    ))))

    var smallestSet: HashSet[seq[byte]]
    let seqs = toSeq(sentMessages)
    if seqs[0] < seqs[1]:
      smallestSet.incl(seqs[0])
    else:
      smallestSet.incl(seqs[1])

    checkExpiring: receivedMessages[] == smallestSet
    check receivedMessages[].len == 1

    await teardownTest(gossip0, gossip1)
