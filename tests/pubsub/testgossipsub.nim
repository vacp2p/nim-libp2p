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
import utils, ../../libp2p/[switch,
                            peer,
                            peerinfo, 
                            connection,
                            crypto/crypto,
                            stream/bufferstream,
                            protocols/pubsub/pubsub,
                            protocols/pubsub/gossipsub,
                            protocols/pubsub/mcache,
                            protocols/pubsub/floodsub,
                            protocols/pubsub/pubsubpeer,
                            protocols/pubsub/rpc/messages]

proc createGossipSub(): GossipSub =
  var peerInfo: PeerInfo
  var seckey = some(PrivateKey.random(RSA))

  peerInfo.peerId = some(PeerID.init(seckey.get()))
  result = newPubSub(GossipSub, peerInfo)

suite "GossipSub":
  # test "should add remote peer topic subscriptios":
  #   proc testRun(): Future[bool] {.async.} =
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       discard

  #     let gossip1 = createGossipSub()
  #     let gossip2 = createGossipSub()

  #     var buf1 = newBufferStream()
  #     var conn1 = newConnection(buf1)
  #     conn1.peerInfo = gossip1.peerInfo

  #     var buf2 = newBufferStream()
  #     var conn2 = newConnection(buf2)
  #     conn2.peerInfo = gossip2.peerInfo

  #     buf1 = buf1 | buf2 | buf1

  #     await gossip1.subscribeToPeer(conn2)
  #     await gossip2.subscribeToPeer(conn1)

  #     await gossip1.subscribe("foobar", handler)
  #     await sleepAsync(1.seconds)

  #     check:
  #        "foobar" in gossip2.gossipsub
  #        gossip1.peerInfo.peerId.get().pretty in gossip2.gossipsub["foobar"]

  #     result = true

  #   check:
  #     waitFor(testRun()) == true

  # test "e2e - should add remote peer topic subscriptios":
  #   proc testBasicFloodSub(): Future[bool] {.async.} =
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  #       discard

  #     var nodes: seq[Switch] = newSeq[Switch]()
  #     for i in 0..<2:
  #       nodes.add(createNode(gossip = true))

  #     var awaitters: seq[Future[void]]
  #     for node in nodes:
  #       awaitters.add(await node.start())

  #     await nodes[1].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await subscribeNodes(nodes)

  #     let gossip1 = GossipSub(nodes[0].pubSub.get())
  #     let gossip2 = GossipSub(nodes[1].pubSub.get())

  #     check:
  #       "foobar" in gossip2.topics
  #       "foobar" in gossip1.gossipsub
  #       gossip2.peerInfo.peerId.get().pretty in gossip1.gossipsub["foobar"]

  #     await allFutures(nodes.mapIt(it.stop()))
  #     await allFutures(awaitters)

  #     result = true

  #   check:
  #     waitFor(testBasicFloodSub()) == true

  # test "should add remote peer topic subscriptios if both peers are subscribed":
  #   proc testRun(): Future[bool] {.async.} =
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       discard

  #     let gossip1 = createGossipSub()
  #     let gossip2 = createGossipSub()

  #     var buf1 = newBufferStream()
  #     var conn1 = newConnection(buf1)
  #     conn1.peerInfo = gossip1.peerInfo

  #     var buf2 = newBufferStream()
  #     var conn2 = newConnection(buf2)
  #     conn2.peerInfo = gossip2.peerInfo
      
  #     buf1 = buf1 | buf2 | buf1

  #     await gossip1.subscribeToPeer(conn2)
  #     await gossip2.subscribeToPeer(conn1)

  #     await gossip1.subscribe("foobar", handler)
  #     await gossip2.subscribe("foobar", handler)
  #     await sleepAsync(1.seconds)

  #     check:
  #        "foobar" in gossip1.topics
  #        "foobar" in gossip2.topics

  #        "foobar" in gossip1.gossipsub
  #        "foobar" in gossip2.gossipsub

  #        gossip2.peerInfo.peerId.get().pretty in gossip1.gossipsub["foobar"]
  #        gossip1.peerInfo.peerId.get().pretty in gossip2.gossipsub["foobar"]

  #     result = true

  #   check:
  #     waitFor(testRun()) == true

  # test "e2e - should add remote peer topic subscriptios if both peers are subscribed":
  #   proc testBasicFloodSub(): Future[bool] {.async.} =
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
  #       discard

  #     var nodes: seq[Switch] = newSeq[Switch]()
  #     for i in 0..<2:
  #       nodes.add(createNode(gossip = true))

  #     var awaitters: seq[Future[void]]
  #     for node in nodes:
  #       awaitters.add(await node.start())

  #     await nodes[0].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await nodes[1].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await subscribeNodes(nodes)

  #     let gossip1 = GossipSub(nodes[0].pubSub.get())
  #     let gossip2 = GossipSub(nodes[1].pubSub.get())

  #     check:
  #       "foobar" in gossip1.topics
  #       "foobar" in gossip2.topics

  #       "foobar" in gossip1.gossipsub
  #       "foobar" in gossip2.gossipsub

  #       gossip1.peerInfo.peerId.get().pretty in gossip2.gossipsub["foobar"]
  #       gossip2.peerInfo.peerId.get().pretty in gossip1.gossipsub["foobar"]

  #     await allFutures(nodes.mapIt(it.stop()))
  #     await allFutures(awaitters)

  #     result = true

  #   check:
  #     waitFor(testBasicFloodSub()) == true

  # test "send over fanout A -> B":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check:
  #         topic == "foobar"
  #         cast[string](data) == "Hello!"

  #       passed = true

  #     let gossip1 = createGossipSub()
  #     let gossip2 = createGossipSub()

  #     var buf1 = newBufferStream()
  #     var conn1 = newConnection(buf1)
  #     conn1.peerInfo = gossip1.peerInfo

  #     var buf2 = newBufferStream()
  #     var conn2 = newConnection(buf2)
  #     conn2.peerInfo = gossip2.peerInfo

  #     buf1 = buf1 | buf2 | buf1

  #     await gossip1.subscribeToPeer(conn2)
  #     await gossip2.subscribeToPeer(conn1)

  #     await gossip1.subscribe("foobar", handler)
  #     await sleepAsync(1.seconds)

  #     await gossip2.publish("foobar", cast[seq[byte]]("Hello!"))
  #     await sleepAsync(1.seconds)
  #     result = passed

  #   check:
  #     waitFor(testRun()) == true

  # test "e2e - send over fanout A -> B":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check topic == "foobar"
  #       passed = true

  #     var nodes = generateNodes(2, true)
  #     var wait = newSeq[Future[void]]()
  #     wait.add(await nodes[0].start())
  #     wait.add(await nodes[1].start())

  #     await subscribeNodes(nodes)

  #     await nodes[1].subscribe("foobar", handler)
  #     await sleepAsync(3.seconds)

  #     await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
  #     await sleepAsync(3.seconds)

  #     var gossipSub1: GossipSub = GossipSub(nodes[0].pubSub.get())

  #     check:
  #       "foobar" in gossipSub1.gossipsub

  #     await nodes[1].stop()
  #     await nodes[0].stop()

  #     await allFutures(wait)
  #     result = passed

  #   check:
  #     waitFor(testRun()) == true

  # test "send over mesh A -> B":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check:
  #         topic == "foobar"
  #         cast[string](data) == "Hello!"

  #       passed = true

  #     let gossip1 = createGossipSub()
  #     let gossip2 = createGossipSub()

  #     var buf1 = newBufferStream()
  #     var conn1 = newConnection(buf1)
  #     conn1.peerInfo = gossip1.peerInfo

  #     var buf2 = newBufferStream()
  #     var conn2 = newConnection(buf2)
  #     conn2.peerInfo = gossip2.peerInfo

  #     buf1 = buf1 | buf2 | buf1

  #     await gossip1.subscribeToPeer(conn2)
  #     await gossip2.subscribeToPeer(conn1)

  #     await gossip1.subscribe("foobar", handler)
  #     await sleepAsync(1.seconds)

  #     await gossip2.subscribe("foobar", handler)
  #     await sleepAsync(1.seconds)

  #     await gossip2.publish("foobar", cast[seq[byte]]("Hello!"))
  #     await sleepAsync(1.seconds)
  #     result = passed

  #   check:
  #     waitFor(testRun()) == true

  # test "e2e - send over mesh A -> B":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check topic == "foobar"
  #       passed = true

  #     var nodes = generateNodes(2, true)
  #     var wait = await nodes[1].start()

  #     await subscribeNodes(nodes)
  #     await sleepAsync(100.millis)

  #     await nodes[0].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await nodes[1].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
  #     await sleepAsync(1000.millis)

  #     await nodes[1].stop()
  #     await allFutures(wait)
  #     result = passed

  #   check:
  #     waitFor(testRun()) == true

  test "with multiple peers": 
    proc testRun(): Future[bool] {.async.} =
      var passed: int
      var nodes: seq[GossipSub]
      for i in 0..<20:
        nodes.add(createGossipSub())

      var pending: seq[Future[void]]
      var awaitters: seq[Future[void]]
      for dialer in nodes:
        var handler: TopicHandler
        closureScope:
          var dialerNode = dialer
          handler = proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
            # echo cast[string](data),
            #      ", target node ",
            #      dialerNode.peerInfo.peerId.get().pretty
            check topic == "foobar"
            passed.inc()

        await dialer.subscribe("foobar", handler)
        await sleepAsync(20.millis)

        for node in nodes:
          if dialer.peerInfo.peerId != node.peerInfo.peerId:
            var buf1 = newBufferStream(size = DefaultBufferSize * 1000)
            var conn1 = newConnection(buf1)
            conn1.peerInfo = dialer.peerInfo

            var buf2 = newBufferStream(size = DefaultBufferSize * 1000)
            var conn2 = newConnection(buf2)
            conn2.peerInfo = node.peerInfo

            buf1 = buf2 | buf1
            buf2 = buf1 | buf2

            pending.add(dialer.subscribeToPeer(conn2))
            pending.add(node.subscribeToPeer(conn1))
            await sleepAsync(10.millis)

        awaitters.add(dialer.start())

      for node in nodes:
        await node.publish("foobar", 
                           cast[seq[byte]]("from node " & 
                           node.peerInfo.peerId.get().pretty))
        await sleepAsync(10.millis)

      await sleepAsync(100.millis)
      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)
      
      echo "PASSED ", passed
      result = passed >= 5

    check:
      waitFor(testRun()) == true

  # test "e2e - with multiple peers":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: int
  #     var nodes: seq[Switch] = newSeq[Switch]()
  #     for i in 0..<10:
  #       nodes.add(createNode(none(PrivateKey), "/ip4/127.0.0.1/tcp/0", true, true))

  #     var awaitters: seq[Future[void]]
  #     for node in nodes:
  #       awaitters.add(await node.start())

  #       var handler: TopicHandler
  #       closureScope:
  #         var dialerNode = node
  #         handler = proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
  #           # echo cast[string](data), ", target node ", dialerNode.peerInfo.peerId.get().pretty
  #           check topic == "foobar"
  #           passed.inc()

  #       await node.subscribe("foobar", handler)
  #       await sleepAsync(10.millis)

  #     await subscribeNodes(nodes)
  #     await sleepAsync(10.millis)

  #     for node in nodes:
  #       await node.publish("foobar", 
  #                          cast[seq[byte]]("from node " & 
  #                          node.peerInfo.peerId.get().pretty))
  #       await sleepAsync(10.millis)

  #     await allFutures(nodes.mapIt(it.stop()))
  #     await allFutures(awaitters)

  #     # echo "PASSED ", passed
  #     result = passed >= 19

  #   check:
  #     waitFor(testRun()) == true
