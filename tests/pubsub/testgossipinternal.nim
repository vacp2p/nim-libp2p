include ../../libp2p/protocols/pubsub/gossipsub

import unittest
import ../../libp2p/errors
import ../../libp2p/stream/bufferstream

import ../helpers

type
  TestGossipSub = ref object of GossipSub

suite "GossipSub internal":
  teardown:
    for tracker in testTrackers():
      check tracker.isLeaked() == false

  test "`rebalanceMesh` Degree Lo":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      let topic = "foobar"
      gossipSub.mesh[topic] = initHashSet[string]()

      var conns = newSeq[Connection]()
      for i in 0..<15:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].conn = conn
        gossipSub.mesh[topic].incl(peerInfo.id)

      check gossipSub.peers.len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`rebalanceMesh` Degree Hi":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      let topic = "foobar"
      gossipSub.gossipsub[topic] = initHashSet[string]()

      var conns = newSeq[Connection]()
      for i in 0..<15:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].conn = conn
        gossipSub.gossipsub[topic].incl(peerInfo.id)

      check gossipSub.gossipsub[topic].len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`replenishFanout` Degree Lo":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.gossipsub[topic] = initHashSet[string]()

      var conns = newSeq[Connection]()
      for i in 0..<15:
        let conn = newConnection(newBufferStream())
        conns &= conn
        var peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        gossipSub.gossipsub[topic].incl(peerInfo.id)

      check gossipSub.gossipsub[topic].len == 15
      await gossipSub.replenishFanout(topic)
      check gossipSub.fanout[topic].len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`dropFanoutPeers` drop expired fanout topics":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.fanout[topic] = initHashSet[string]()
      gossipSub.lastFanoutPubSub[topic] = Moment.fromNow(100.millis)

      var conns = newSeq[Connection]()
      for i in 0..<6:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        gossipSub.fanout[topic].incl(peerInfo.id)

      check gossipSub.fanout[topic].len == GossipSubD

      await gossipSub.dropFanoutPeers()
      check topic notin gossipSub.fanout

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`dropFanoutPeers` leave unexpired fanout topics":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic1 = "foobar1"
      let topic2 = "foobar2"
      gossipSub.fanout[topic1] = initHashSet[string]()
      gossipSub.fanout[topic2] = initHashSet[string]()
      gossipSub.lastFanoutPubSub[topic1] = Moment.fromNow(100.millis)
      gossipSub.lastFanoutPubSub[topic2] = Moment.fromNow(5.seconds)

      var conns = newSeq[Connection]()
      for i in 0..<6:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        gossipSub.fanout[topic1].incl(peerInfo.id)
        gossipSub.fanout[topic2].incl(peerInfo.id)

      check gossipSub.fanout[topic1].len == GossipSubD
      check gossipSub.fanout[topic2].len == GossipSubD

      await gossipSub.dropFanoutPeers()
      check topic1 notin gossipSub.fanout
      check topic2 in gossipSub.fanout

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should gather up to degree D non intersecting peers":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.mesh[topic] = initHashSet[string]()
      gossipSub.fanout[topic] = initHashSet[string]()
      gossipSub.gossipsub[topic] = initHashSet[string]()
      var conns = newSeq[Connection]()
      for i in 0..<30:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        if i mod 2 == 0:
          gossipSub.fanout[topic].incl(peerInfo.id)
        else:
          gossipSub.mesh[topic].incl(peerInfo.id)

      for i in 0..<15:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        gossipSub.gossipsub[topic].incl(peerInfo.id)

      check gossipSub.fanout[topic].len == 15
      check gossipSub.fanout[topic].len == 15
      check gossipSub.gossipsub[topic].len == 15

      let peers = gossipSub.getGossipPeers()
      check peers.len == GossipSubD
      for p in peers.keys:
        check p notin gossipSub.fanout[topic]
        check p notin gossipSub.mesh[topic]

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in mesh":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.fanout[topic] = initHashSet[string]()
      gossipSub.gossipsub[topic] = initHashSet[string]()
      var conns = newSeq[Connection]()
      for i in 0..<30:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        if i mod 2 == 0:
          gossipSub.fanout[topic].incl(peerInfo.id)
        else:
          gossipSub.gossipsub[topic].incl(peerInfo.id)

      let peers = gossipSub.getGossipPeers()
      check peers.len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in gossip":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.mesh[topic] = initHashSet[string]()
      gossipSub.gossipsub[topic] = initHashSet[string]()
      var conns = newSeq[Connection]()
      for i in 0..<30:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        if i mod 2 == 0:
          gossipSub.mesh[topic].incl(peerInfo.id)
        else:
          gossipSub.gossipsub[topic].incl(peerInfo.id)

      let peers = gossipSub.getGossipPeers()
      check peers.len == GossipSubD

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true

  test "`getGossipPeers` - should not crash on missing topics in gossip":
    proc testRun(): Future[bool] {.async.} =
      let gossipSub = newPubSub(TestGossipSub,
                                PeerInfo.init(PrivateKey.random(RSA).get()))

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async.} =
        discard

      let topic = "foobar"
      gossipSub.mesh[topic] = initHashSet[string]()
      gossipSub.fanout[topic] = initHashSet[string]()
      var conns = newSeq[Connection]()
      for i in 0..<30:
        let conn = newConnection(newBufferStream())
        conns &= conn
        let peerInfo = PeerInfo.init(PrivateKey.random(RSA).get())
        conn.peerInfo = peerInfo
        gossipSub.peers[peerInfo.id] = newPubSubPeer(peerInfo, GossipSubCodec)
        gossipSub.peers[peerInfo.id].handler = handler
        if i mod 2 == 0:
          gossipSub.mesh[topic].incl(peerInfo.id)
        else:
          gossipSub.fanout[topic].incl(peerInfo.id)

      let peers = gossipSub.getGossipPeers()
      check peers.len == 0

      await allFuturesThrowing(conns.mapIt(it.close()))

      result = true

    check:
      waitFor(testRun()) == true
