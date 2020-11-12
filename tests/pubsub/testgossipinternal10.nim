include ../../libp2p/protocols/pubsub/gossipsub10

{.used.}

import options
import unittest, bearssl
import stew/byteutils
import ../../libp2p/standard_setup
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream

import ../helpers

type
  TestGossipSub = ref object of GossipSub

proc noop(data: seq[byte]) {.async, gcsafe.} = discard

proc getPubSubPeer(p: TestGossipSub, peerId: PeerID): auto =
  proc getConn(): Future[Connection] =
    p.switch.dial(peerId, GossipSubCodec)

  newPubSubPeer(peerId, getConn, nil, GossipSubCodec)

proc randomPeerInfo(): PeerInfo =
  PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())

suite "GossipSub internal":
  teardown:
    checkTrackers()

  asyncTest "`rebalanceMesh` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.sendConn = conn
      gossipSub.peers[peerInfo.peerId] = peer
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.peers.len == 15
    await gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == GossipSubD

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`rebalanceMesh` Degree Hi":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topics[topic] = Topic() # has to be in topics to rebalance

    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.peers[peerInfo.peerId] = peer
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 15
    await gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == GossipSubD

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`replenishFanout` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

    var conns = newSeq[Connection]()
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      var peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.gossipsub[topic].len == 15
    gossipSub.replenishFanout(topic)
    check gossipSub.fanout[topic].len == GossipSubD

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` drop expired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic] = Moment.fromNow(1.millis)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0..<6:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      gossipSub.fanout[topic].incl(peer)

    check gossipSub.fanout[topic].len == GossipSubD

    gossipSub.dropFanoutPeers()
    check topic notin gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTEst "`dropFanoutPeers` leave unexpired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic1 = "foobar1"
    let topic2 = "foobar2"
    gossipSub.fanout[topic1] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic2] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic1] = Moment.fromNow(1.millis)
    gossipSub.lastFanoutPubSub[topic2] = Moment.fromNow(1.minutes)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0..<6:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      gossipSub.fanout[topic1].incl(peer)
      gossipSub.fanout[topic2].incl(peer)

    check gossipSub.fanout[topic1].len == GossipSubD
    check gossipSub.fanout[topic2].len == GossipSubD

    gossipSub.dropFanoutPeers()
    check topic1 notin gossipSub.fanout
    check topic2 in gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should gather up to degree D non intersecting peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()

    # generate mesh and fanout peers
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      inc seqno
      let msg = Message.init(some(peerInfo), ("HELLO" & $i).toBytes(), topic, some(seqno), false)
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let peers = gossipSub.getGossipPeers()
    check peers.len == GossipSubD
    for p in peers.keys:
      check not gossipSub.fanout.hasPeerID(topic, p.peerId)
      check not gossipSub.mesh.hasPeerID(topic, p.peerId)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      inc seqno
      let msg = Message.init(some(peerInfo), ("HELLO" & $i).toBytes(), topic, some(seqno), false)
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == GossipSubD

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      inc seqno
      let msg = Message.init(some(peerInfo), ("HELLO" & $i).toBytes(), topic, some(seqno), false)
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == GossipSubD

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      inc seqno
      let msg = Message.init(some(peerInfo), ("bar" & $i).toBytes(), topic, some(seqno), false)
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()
