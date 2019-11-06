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
                     peer,
                     peerinfo, 
                     connection,
                     crypto/crypto,
                     stream/lpstream,
                     protocols/pubsub/pubsub,
                     protocols/pubsub/gossipsub,
                     protocols/pubsub/mcache,
                     protocols/pubsub/floodsub,
                     protocols/pubsub/pubsubpeer,
                     protocols/pubsub/rpc/messages]

suite "GossipSub":
  # test "GossipSub send over fanout A -> B":
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check topic == "foobar"
  #       passed = true

  #     var nodes = generateNodes(2, true)
  #     var wait = await nodes[1].start()

  #     await subscribeNodes(nodes)

  #     await nodes[1].subscribe("foobar", handler)
  #     await sleepAsync(100.millis)

  #     await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
  #     await sleepAsync(100.millis)

  #     await nodes[1].stop()
  #     await allFutures(wait)
  #     result = passed

  #   check:
  #     waitFor(testRun()) == true

  # test "GossipSub send over mesh A -> B": 
  #   proc testRun(): Future[bool] {.async.} =
  #     var passed: bool
  #     proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
  #       check topic == "foobar"
  #       passed = true

  #     var nodes = generateNodes(2, true)
  #     var wait = await nodes[1].start()

  #     await subscribeNodes(nodes)

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

  test "GossipSub with multiple peers":
    proc testRun(): Future[bool] {.async.} =
      var passed: int
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
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
