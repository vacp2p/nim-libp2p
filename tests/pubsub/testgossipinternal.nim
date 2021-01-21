include ../../libp2p/protocols/pubsub/gossipsub

{.used.}

import options
import unittest, bearssl
import stew/byteutils
import ../../libp2p/standard_setup
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream
import ../../libp2p/switch

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
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.sendConn = conn
      gossipSub.onNewPeer(peer)
      gossipSub.peers[peerInfo.peerId] = peer
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
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      peer.sendConn = conn
      gossipSub.onNewPeer(peer)
      gossipSub.peers[peerInfo.peerId] = peer
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d # + 2 # account opportunistic grafts

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
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      gossipSub.grafted(peer, topic)
      gossipSub.peers[peerInfo.peerId] = peer
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d + gossipSub.parameters.dScore

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`replenishFanout` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      var peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.gossipsub[topic].len == 15
    gossipSub.replenishFanout(topic)
    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` drop expired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
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
      gossipSub.onNewPeer(peer)
      peer.handler = handler
      gossipSub.fanout[topic].incl(peer)

    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic notin gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` leave unexpired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
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
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
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

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
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
      gossipSub.onNewPeer(peer)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 0..<15:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
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
    check peers.len == gossipSub.parameters.d
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
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
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
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
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
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
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

  asyncTest "Drop messages of topics without subscription":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      peer.handler = handler

    # generate messages
    var seqno = 0'u64
    for i in 0..5:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      inc seqno
      let msg = Message.init(some(peerInfo), ("bar" & $i).toBytes(), topic, some(seqno), false)
      await gossipSub.rpcHandler(peer, RPCMsg(messages: @[msg]))

    check gossipSub.mcache.msgs.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "Disconnect bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.parameters.disconnectBadPeers = true

    proc handler(peer: PubSubPeer, msg: RPCMsg) {.async.} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0..<30:
      let conn = newBufferStream(noop)
      conns &= conn
      let peerInfo = randomPeerInfo()
      conn.peerInfo = peerInfo
      let peer = gossipSub.getPubSubPeer(peerInfo.peerId)
      gossipSub.onNewPeer(peer)
      peer.sendConn = conn
      peer.handler = handler
      peer.score = gossipSub.parameters.graylistThreshold - 1
      gossipSub.gossipsub.mgetOrPut(topic, initHashSet[PubSubPeer]()).incl(peer)
      gossipSub.peers[peerInfo.peerId] = peer
      gossipSub.switch.connManager.storeConn(conn)

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()
