## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest, sequtils, options
import chronos
import utils,
       ../../libp2p/[switch, crypto/crypto]

suite "FloodSub":
  test "FloodSub basic publish/subscribe A -> B":
    proc testBasicPubSub(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        completionFut.complete(true)

      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      await subscribeNodes(nodes)
      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(1000.millis)

      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))

      result = await completionFut
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)

    check:
      waitFor(testBasicPubSub()) == true

  test "FloodSub basic publish/subscribe B -> A":
    proc testBasicPubSub(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        completionFut.complete(true)

      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      await subscribeNodes(nodes)
      await nodes[0].subscribe("foobar", handler)
      await sleepAsync(1000.millis)

      await nodes[1].publish("foobar", cast[seq[byte]]("Hello!"))

      result = await completionFut
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)

    check:
      waitFor(testBasicPubSub()) == true

  test "FloodSub multiple peers, no self trigger":
    proc testBasicFloodSub(): Future[bool] {.async.} =
      var passed: int
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        passed.inc()

      var nodes: seq[Switch] = newSeq[Switch]()
      for i in 0..<10:
        nodes.add(newStandardSwitch())

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

      result = passed >= 10 # non deterministic, so at least 2 times

    check:
      waitFor(testBasicFloodSub()) == true

  test "FloodSub multiple peers, with self trigger":
    proc testBasicFloodSub(): Future[bool] {.async.} =
      var passed: int
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        passed.inc()

      var nodes: seq[Switch] = newSeq[Switch]()
      for i in 0..<10:
        nodes.add newStandardSwitch(triggerSelf = true)

      var awaitters: seq[Future[void]]
      for node in nodes:
        awaitters.add((await node.start()))
        await node.subscribe("foobar", handler)
        await sleepAsync(10.millis)

      await subscribeNodes(nodes)
      await sleepAsync(500.millis)

      for node in nodes:
        await node.publish("foobar", cast[seq[byte]]("Hello!"))
        await sleepAsync(10.millis)

      await sleepAsync(100.millis)

      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)

      result = passed >= 10 # non deterministic, so at least 20 times

    check:
      waitFor(testBasicFloodSub()) == true
