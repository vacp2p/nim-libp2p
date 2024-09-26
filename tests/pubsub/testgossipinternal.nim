# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
import ../utils/[futures]

import ../helpers

import std/[tables, sequtils, sets, strutils]

proc voidTopicHandler(topic: string, data: seq[byte]) {.async.} =
  discard

proc noop(data: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  discard

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
    for i in 0 ..< 15:
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
    for i in 0 ..< 15:
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
    for i in 0 ..< 15:
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
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len ==
      gossipSub.parameters.d + gossipSub.parameters.dScore

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
    for i in 0 ..< 15:
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
    for i in 0 ..< 6:
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
    for i in 0 ..< 6:
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
    for i in 0 ..< 30:
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
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
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
    for i in 0 ..< 30:
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
    for i in 0 .. 5:
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
    for i in 0 ..< 30:
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
    for i in 0 .. 5:
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
    for i in 0 ..< 30:
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
    for i in 0 .. 5:
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
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
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
    for i in 0 ..< 30:
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
    await gossipSub.switch.stop()

  asyncTest "invalid message bytes":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let peerId = randomPeerId()
    let peer = gossipSub.getPubSubPeer(peerId)

    expect(CatchableError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh fail due to backoff":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

      gossipSub.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]()).add(
        peerId, Moment.now() + 1.hours
      )
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
    for i in 0 ..< 15:
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

    for i in 0 ..< 15:
      let peerId = conns[i].peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.handlePrune(
        peer,
        @[
          ControlPrune(
            topicID: topic,
            peers: @[],
            backoff: gossipSub.parameters.pruneBackoff.seconds.uint64,
          )
        ],
      )

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
    for i in 0 ..< 6:
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

    for i in 0 ..< 7:
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

    proc handler2(topic: string, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.subscribe(topic, handler2)

    for i in 0 ..< 30:
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
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      peer.iHaveBudget = 0
      let iwants = gossipSub.handleIHave(peer, @[msg])
      check:
        iwants.messageIDs.len == 0

    block:
      # given duplicate ihave should generate only one iwant
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      let iwants = gossipSub.handleIHave(peer, @[msg])
      check:
        iwants.messageIDs.len == 1

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
      let msg = ControlIWant(messageIDs: @[id, id, id])
      let genmsg = gossipSub.handleIWant(peer, @[msg])
      check:
        genmsg.len == 1

    check gossipSub.mcache.msgs.len == 1

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  proc setupTest(): Future[
      tuple[
        gossip0: GossipSub, gossip1: GossipSub, receivedMessages: ref HashSet[seq[byte]]
      ]
  ] {.async.} =
    let nodes = generateNodes(2, gossip = true, verifySignature = false)
    discard await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await nodes[1].switch.connect(
      nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
    )

    var receivedMessages = new(HashSet[seq[byte]])

    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      receivedMessages[].incl(data)

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      discard

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip0: GossipSub = GossipSub(nodes[0])
    var gossip1: GossipSub = GossipSub(nodes[1])

    return (gossip0, gossip1, receivedMessages)

  proc teardownTest(gossip0: GossipSub, gossip1: GossipSub) {.async.} =
    await allFuturesThrowing(gossip0.switch.stop(), gossip1.switch.stop())

  proc createMessages(
      gossip0: GossipSub, gossip1: GossipSub, size1: int, size2: int
  ): tuple[iwantMessageIds: seq[MessageId], sentMessages: HashSet[seq[byte]]] =
    var iwantMessageIds = newSeq[MessageId]()
    var sentMessages = initHashSet[seq[byte]]()

    for i, size in enumerate([size1, size2]):
      let data = newSeqWith[byte](size, i.byte)
      sentMessages.incl(data)

      let msg =
        Message.init(gossip1.peerInfo.peerId, data, "foobar", some(uint64(i + 1)))
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
    let (iwantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: iwantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Discard IWANT replies when both messages individually exceed maxSize":
    # This test checks if two messages, each exceeding the maxSize, are discarded and not sent.
    # Expected: No messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()

    let messageSize = gossip1.maxMessageSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    await sleepAsync(300.milliseconds)
    checkUntilTimeout:
      receivedMessages[].len == 0

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Process IWANT replies when both messages are below maxSize":
    # This test checks if two messages, both below the maxSize, are correctly processed and sent.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let size1 = gossip1.maxMessageSize div 2
    let size2 = gossip1.maxMessageSize div 3
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Split IWANT replies when one message is below maxSize and the other exceeds maxSize":
    # This test checks if, when given two messages where one is below maxSize and the other exceeds it, only the smaller message is processed and sent.
    # Expected: Only the smaller message should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let maxSize = gossip1.maxMessageSize
    let size1 = maxSize div 2
    let size2 = maxSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    var smallestSet: HashSet[seq[byte]]
    let seqs = toSeq(sentMessages)
    if seqs[0] < seqs[1]:
      smallestSet.incl(seqs[0])
    else:
      smallestSet.incl(seqs[1])

    checkUntilTimeout:
      receivedMessages[] == smallestSet
    check receivedMessages[].len == 1

    await teardownTest(gossip0, gossip1)

  asyncTest "GRAFT messages correctly add peers to mesh":
    # Potentially flaky test

    # Given 2 nodes
    let
      topic = "foobar"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      # First part of the hack: Weird dValues so peers are not GRAFTed automatically
      dValues = DValues(dLow: some(0), dHigh: some(0), d: some(0), dOut: some(-1))
      nodes = generateNodes(
        numberOfNodes, gossip = true, verifySignature = false, dValues = some(dValues)
      )
      nodesFut = nodes.mapIt(it.switch.start())
      g0 = GossipSub(nodes[0])
      g1 = GossipSub(nodes[1])
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)
      p0 = tg1.getPubSubPeer(nodes[0].peerInfo.peerId)
      p1 = tg0.getPubSubPeer(nodes[1].peerInfo.peerId)

    discard await allFinished(nodesFut)

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And both subscribe to the topic
    g0.subscribe(topic, voidTopicHandler)
    g1.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # Because of the hack-ish dValues, the peers are added to gossipsub but not GRAFTed to mesh
    check:
      g0.gossipsub.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, nodes[0].peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, nodes[1].peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, nodes[0].peerInfo.peerId) == false

    # Second part of the hack
    # Set values so peers can be GRAFTed
    g0.parameters.dOut = 1
    g0.parameters.d = 1
    g0.parameters.dLow = 1
    g0.parameters.dHigh = 1
    g1.parameters.dOut = 1
    g1.parameters.d = 1
    g1.parameters.dLow = 1
    g1.parameters.dHigh = 1

    # Potentially flaky due to this relying on sleep. Race condition against heartbeat.
    # When a GRAFT message is sent
    g0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    g1.broadcast(@[p0], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    # Minimal await to avoid heartbeat so that the GRAFT is due to the message
    # Despite this, it could happen that it's due to heartbeat, even if local tests didn't show that behaviour
    await sleepAsync(300.milliseconds)

    # Then the peers are GRAFTed
    check:
      g0.gossipsub.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, nodes[0].peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.mesh.hasPeerId(topic, nodes[0].peerInfo.peerId) == true

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "PRUNE messages correctly removes peers from mesh":
    # Given 2 nodes
    let
      topic = "foo"
      backoff = 1
      pruneMessage = ControlMessage(
        prune: @[ControlPrune(topicID: topic, peers: @[], backoff: uint64(backoff))]
      )
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      g0 = GossipSub(nodes[0])
      g1 = GossipSub(nodes[1])
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)
      p0 = tg1.getPubSubPeer(nodes[0].peerInfo.peerId)
      p1 = tg0.getPubSubPeer(nodes[1].peerInfo.peerId)

    discard await allFinished(nodesFut)

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And both subscribe to the topic
    g0.subscribe(topic, voidTopicHandler)
    g1.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    check:
      g0.gossipsub.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, nodes[0].peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.mesh.hasPeerId(topic, nodes[0].peerInfo.peerId) == true

    # When a PRUNE message is sent
    g0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await sleepAsync(300.milliseconds)

    # Then the peer is PRUNEd
    check:
      g0.gossipsub.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, nodes[0].peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.mesh.hasPeerId(topic, nodes[0].peerInfo.peerId) == false

    # When another PRUNE message is sent
    g1.broadcast(@[p0], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await sleepAsync(300.milliseconds)

    # Then the peer is PRUNEd
    check:
      g0.gossipsub.hasPeerId(topic, nodes[1].peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, nodes[0].peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, nodes[1].peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, nodes[0].peerInfo.peerId) == false

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "IHAVE messages correctly advertise message ID to peers":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)

    discard await allFinished(nodesFut)

    # Given node1 has an IHAVE observer
    var receivedIHave = newFuture[(string, seq[MessageId])]()
    let checkForIhaves = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iHave = msgs.control.get.ihave
        if iHave.len > 0:
          for msg in iHave:
            receivedIHave.complete((msg.topicID, msg.messageIDs))

    g1.addObserver(PubSubObserver(onRecv: checkForIhaves))

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And both subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    check:
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true

    # When an IHAVE message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
    await sleepAsync(DURATION_TIMEOUT_SHORT)

    # Then the peer has the message ID
    let r = await receivedIHave.waitForResult(DURATION_TIMEOUT)
    check:
      r.isOk and r.value == (topic, @[messageID])

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "IWANT messages correctly request messages by their IDs":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      iwantMessage = ControlMessage(iwant: @[ControlIWant(messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)

    discard await allFinished(nodesFut)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iWant = msgs.control.get.iwant
        if iWant.len > 0:
          for msg in iWant:
            receivedIWant.complete(msg.messageIDs)

    g1.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And both subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    check:
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == true
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true

    # When an IWANT message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(iwantMessage)), isHighPriority = false)
    await sleepAsync(DURATION_TIMEOUT_SHORT)

    # Then the peer has the message ID
    let r = await receivedIWant.waitForResult(DURATION_TIMEOUT)
    check:
      r.isOk and r.value == @[messageID]

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "Received GRAFT for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)

    discard await allFinished(nodesFut)

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And only node0 subscribes to the topic
    n0.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    check:
      g0.topics.hasKey(topic) == true
      g1.topics.hasKey(topic) == false
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, n0.peerInfo.peerId) == false

    # When a GRAFT message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    await sleepAsync(DURATION_TIMEOUT_SHORT)

    # Then the peer is not GRAFTed
    check:
      g0.topics.hasKey(topic) == true
      g1.topics.hasKey(topic) == false
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, n0.peerInfo.peerId) == false

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "Received PRUNE for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      pruneMessage =
        ControlMessage(prune: @[ControlPrune(topicID: topic, peers: @[], backoff: 1)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)

    discard await allFinished(nodesFut)

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And only node0 subscribes to the topic
    n0.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    check:
      g0.topics.hasKey(topic) == true
      g1.topics.hasKey(topic) == false
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, n0.peerInfo.peerId) == false

    # When a PRUNE message is sent
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await sleepAsync(DURATION_TIMEOUT_SHORT)

    # Then the peer is not PRUNEd
    check:
      g0.topics.hasKey(topic) == true
      g1.topics.hasKey(topic) == false
      g0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId) == true
      g0.mesh.hasPeerId(topic, n1.peerInfo.peerId) == false
      g1.mesh.hasPeerId(topic, n0.peerInfo.peerId) == false

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  asyncTest "IHAVE for non-existent topic":
    # Given 2 nodes
    let
      topic = "foo"
      messageID = @[0'u8, 1, 2, 3]
      ihaveMessage =
        ControlMessage(ihave: @[ControlIHave(topicID: topic, messageIDs: @[messageID])])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
      nodesFut = nodes.mapIt(it.switch.start())
      n0 = nodes[0]
      n1 = nodes[1]
      g0 = GossipSub(n0)
      g1 = GossipSub(n1)
      tg0 = cast[TestGossipSub](g0)
      tg1 = cast[TestGossipSub](g1)

    discard await allFinished(nodesFut)

    # Given node1 has an IWANT observer
    var receivedIWant = newFuture[seq[MessageId]]()
    let checkForIwants = proc(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iWant = msgs.control.get.iwant
        if iWant.len > 0:
          for msg in iWant:
            receivedIWant.complete(msg.messageIDs)

    g0.addObserver(PubSubObserver(onRecv: checkForIwants))

    # And the nodes are connected
    await subscribeNodes(nodes)

    # And both nodes subscribe to the topic
    n0.subscribe(topic, voidTopicHandler)
    n1.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When an IHAVE message is sent from node0
    let p1 = g0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    g0.broadcast(@[p1], RPCMsg(control: some(ihaveMessage)), isHighPriority = false)
    await sleepAsync(DURATION_TIMEOUT_SHORT)

    # Then node0 should receive an IWANT message from node1 (as node1 doesn't have the message)
    let iWantResult = await receivedIWant.waitForResult(DURATION_TIMEOUT)
    check:
      iWantResult.isOk and iWantResult.value == @[messageID]

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))
