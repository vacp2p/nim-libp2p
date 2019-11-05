## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest, sequtils, options, tables, sets
import chronos
import utils, 
       ../../libp2p/[switch,
                     crypto/crypto, 
                     protocols/pubsub/pubsub,
                     protocols/pubsub/gossipsub,
                     protocols/pubsub/mcache,
                     protocols/pubsub/floodsub,
                     protocols/pubsub/pubsubpeer,
                     protocols/pubsub/rpc/messages,
                     peer,
                     peerinfo, 
                     connection,
                     stream/lpstream]

type
  TestGossipSub = ref object of GossipSub

method initPubSub*(g: TestGossipSub) =
  ## Override here to prevent interval 
  ## from running
  procCall FloodSub(g).initPubSub()

  g.mcache = newMCache(GossipSubHistoryGossip, GossipSubHistoryLength)
  g.mesh = initTable[string, HashSet[string]]() # meshes - topic to peer
  g.fanout = initTable[string, HashSet[string]]() # fanout - topic to peer
  g.gossipsub = initTable[string, HashSet[string]]() # topic to peer map of all gossipsub peers
  g.lastFanoutPubSub = initTable[string, Duration]() # last publish time for fanout topics
  g.gossip = initTable[string, seq[ControlIHave]]() # pending gossip
  g.control = initTable[string, ControlMessage]() # pending control messages

type
  TestSelectStream = ref object of LPStream
    step*: int

method readExactly*(s: TestSelectStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] 
  {.async, gcsafe.} = discard

method write*(s: TestSelectStream, msg: seq[byte], msglen = -1)
  {.async, gcsafe.} = discard

method write*(s: TestSelectStream, msg: string, msglen = -1)
  {.async, gcsafe.} = discard

method close(s: TestSelectStream) {.async, gcsafe.} = s.closed = true

suite "GossipSub":
  test "Rebalance `rebalanceMesh` Degree Hi":
    proc testRun(): Future[bool] {.async.} =
      var peerInfo: PeerInfo
      var seckey = some(PrivateKey.random(RSA))

      peerInfo.peerId = some(PeerID.init(seckey.get()))
      let gossipSub = newPubSub(GossipSub, peerInfo)

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async, gcsafe.} = 
        discard

      let topic = "foobar"
      gossipSub.mesh[topic] = initHashSet[string]()
      for i in 0..<15:
        let conn = newConnection(new TestSelectStream)
        let peerId = PeerID.init(PrivateKey.random(RSA))
        conn.peerInfo.peerId = some(peerId)
        gossipSub.peers[peerId.pretty] = newPubSubPeer(conn, handler, GossipSubCodec)
        gossipSub.mesh[topic].incl(peerId.pretty)

      check gossipSub.peers.len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == 6
      
      result = true

    check:
      waitFor(testRun()) == true

  test "Rebalance `rebalanceMesh` Degree Lo":
    proc testRun(): Future[bool] {.async.} =
      var peerInfo: PeerInfo
      var seckey = some(PrivateKey.random(RSA))
      
      peerInfo.peerId = some(PeerID.init(seckey.get()))
      let gossipSub = newPubSub(GossipSub, peerInfo)

      proc handler(peer: PubSubPeer, msg: seq[RPCMsg]) {.async, gcsafe.} = 
        discard

      let topic = "foobar"
      gossipSub.gossipsub[topic] = initHashSet[string]()
      for i in 0..<15:
        let conn = newConnection(new TestSelectStream)
        let peerId = PeerID.init(PrivateKey.random(RSA))
        conn.peerInfo.peerId = some(peerId)
        gossipSub.peers[peerId.pretty] = newPubSubPeer(conn, handler, GossipSubCodec)
        gossipSub.gossipsub[topic].incl(peerId.pretty)

      check gossipSub.gossipsub[topic].len == 15
      await gossipSub.rebalanceMesh(topic)
      check gossipSub.mesh[topic].len == 6
      
      result = true

    check:
      waitFor(testRun()) == true

  test "GossipSub send over fanout A -> B":
    proc testRun(): Future[bool] {.async.} =
      var passed: bool
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
        check topic == "foobar"
        passed = true

      var nodes = generateNodes(2, true)
      var wait = await nodes[1].start()

      await subscribeNodes(nodes)

      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(100.millis)

      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
      await sleepAsync(100.millis)

      await nodes[1].stop()
      await allFutures(wait)
      result = passed

    check:
      waitFor(testRun()) == true

  test "GossipSub send over mesh A -> B": 
    proc testRun(): Future[bool] {.async.} =
      var passed: bool
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
        check topic == "foobar"
        passed = true

      var nodes = generateNodes(2, true)
      var wait = await nodes[1].start()

      await subscribeNodes(nodes)

      await nodes[0].subscribe("foobar", handler)
      await sleepAsync(100.millis)

      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(100.millis)

      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
      await sleepAsync(1000.millis)

      await nodes[1].stop()
      await allFutures(wait)
      result = passed

    check:
      waitFor(testRun()) == true

  test "GossipSub with multiple peers":
    proc testRun(): Future[bool] {.async.} =
      var passed: int
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        writeStackTrace()
        check topic == "foobar"
        passed.inc()

      var nodes: seq[Switch] = newSeq[Switch]()
      for i in 0..<20:
        nodes.add(createNode(none(PrivateKey), "/ip4/127.0.0.1/tcp/0", true, true))

      var awaitters: seq[Future[void]]
      for node in nodes:
        awaitters.add(await node.start())
        await node.subscribe("foobar", handler)
        await sleepAsync(10.millis)

      await subscribeNodes(nodes)
      await sleepAsync(10.millis)

      for node in nodes:
        await node.publish("foobar", cast[seq[byte]]("Hello!"))
        await sleepAsync(10.millis)

      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)

      result = passed == 20

    check:
      waitFor(testRun()) == true
