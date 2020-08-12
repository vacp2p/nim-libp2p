include ../../libp2p/protocols/pubsub/gossipsub

{.used.}

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

proc randomPeerInfo(): PeerInfo =
  PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())

suite "GossipSub internal":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "`rebalanceMesh` Degree Lo":
    proc testRun(): Future[bool] {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipSub.switch, GossipSubCodec)
        gossipSub.peers[peerInfo.peerId] = peer
        gossipSub.mesh[topic].incl(peer)

      check gossipSub.peers.len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()
      result = true

    check:
      waitFor(testRun()) == true

  test "`rebalanceMesh` Degree Hi":
    proc testRun(): Future[bool] {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
        gossipSub.peers[peerInfo.peerId] = peer
        gossipSub.mesh[topic].incl(peer)

      check gossipSub.mesh[topic].len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true

  test "`replenishFanout` Degree Lo":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

      var conns = newSeq[Connection]()
      for i in 0..<15:
        let conn = newBufferStream(noop)
        conns &= conn
        var peerInfo = randomPeerInfo()
        conn.peerInfo = peerInfo
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
        peer.handler = handler
        gossipSub.gossipsub[topic].incl(peer)

      check gossipSub.gossipsub[topic].len == 15
      gossipSub.replenishFanout(topic)
      check gossipSub.fanout[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true

  test "`dropFanoutPeers` drop expired fanout topics":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
        peer.handler = handler
        gossipSub.fanout[topic].incl(peer)

      check gossipSub.fanout[topic].len == GossipSubD

      gossipSub.dropFanoutPeers()
      check topic notin gossipSub.fanout

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true

  test "`dropFanoutPeers` leave unexpired fanout topics":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
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

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should gather up to degree D non intersecting peers":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
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
        let msg = Message.init(peerInfo, ("HELLO" & $i).toBytes(), topic, seqno, false)
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

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in mesh":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipsub.switch, GossipSubCodec)
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
        let msg = Message.init(peerInfo, ("HELLO" & $i).toBytes(), topic, seqno, false)
        gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

      let peers = gossipSub.getGossipPeers()
      check peers.len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in fanout":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipSub.switch, GossipSubCodec)
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
        let msg = Message.init(peerInfo, ("HELLO" & $i).toBytes(), topic, seqno, false)
        gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

      let peers = gossipSub.getGossipPeers()
      check peers.len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in gossip":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = TestGossipSub.init(newStandardSwitch())

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
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
        let peer = newPubSubPeer(peerInfo.peerId, gossipSub.switch, GossipSubCodec)
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
        let msg = Message.init(peerInfo, ("bar" & $i).toBytes(), topic, seqno, false)
        gossipSub.mcache.put(gossipSub.msgIdProvider(msg), msg)

      let peers = gossipSub.getGossipPeers()
      check peers.len == 0

      await allFuturesThrowing(conns.mapIt(it.close()))
      await gossipSub.switch.stop()

      result = true

    check:
      waitFor(testRun()) == true
