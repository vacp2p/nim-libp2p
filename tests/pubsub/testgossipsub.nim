## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest
import chronos
import utils, ../../libp2p/switch

suite "GossipSub":
  test "GossipSub send over fanout A -> B":
    proc testBasicPubSub(): Future[bool] {.async.} =
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
      waitFor(testBasicPubSub()) == true

  test "GossipSub send over mesh A -> B": 
    proc testBasicPubSub(): Future[bool] {.async.} =
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
      waitFor(testBasicPubSub()) == true
