## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest, sequtils
import chronos
import utils,
       ../../libp2p/[switch,
                     crypto/crypto,
                     protocols/pubsub/pubsub,
                     protocols/pubsub/rpc/messages,
                     protocols/pubsub/rpc/message]

suite "FloodSub":
  test "FloodSub basic publish/subscribe A -> B":
    proc runTests(): Future[bool] {.async.} =
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
      waitFor(runTests()) == true

  test "FloodSub basic publish/subscribe B -> A":
    proc runTests(): Future[bool] {.async.} =
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
      waitFor(runTests()) == true

  test "FloodSub validation should succeed":
    proc runTests(): Future[bool] {.async.} =
      var handlerFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        handlerFut.complete(true)

      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      await subscribeNodes(nodes)
      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(1000.millis)

      var validatorFut = newFuture[bool]()
      proc validator(topic: string,
                     message: Message): Future[bool] {.async.} =
        check topic == "foobar"
        validatorFut.complete(true)
        result = true

      nodes[1].addValidator("foobar", validator)
      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))

      await allFutures(handlerFut, handlerFut)
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)
      result = true

    check:
      waitFor(runTests()) == true

  test "FloodSub validation should fail":
    proc runTests(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check false # if we get here, it should fail

      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      await subscribeNodes(nodes)
      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(100.millis)

      var validatorFut = newFuture[bool]()
      proc validator(topic: string,
                     message: Message): Future[bool] {.async.} =
        validatorFut.complete(true)
        result = false

      nodes[1].addValidator("foobar", validator)
      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)
      result = true

    check:
      waitFor(runTests()) == true

  test "FloodSub validation one fails and one succeeds":
    proc runTests(): Future[bool] {.async.} =
      var handlerFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foo"
        handlerFut.complete(true)

      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      await subscribeNodes(nodes)
      await nodes[1].subscribe("foo", handler)
      await nodes[1].subscribe("bar", handler)
      await sleepAsync(1000.millis)

      proc validator(topic: string,
                     message: Message): Future[bool] {.async.} =
        if topic == "foo":
          result = true
        else:
          result = false

      nodes[1].addValidator("foo", "bar", validator)
      await nodes[0].publish("foo", cast[seq[byte]]("Hello!"))
      await nodes[0].publish("bar", cast[seq[byte]]("Hello!"))

      await sleepAsync(100.millis)
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)
      result = true

    check:
      waitFor(runTests()) == true

  test "FloodSub multiple peers, no self trigger":
    proc runTests(): Future[bool] {.async.} =
      var passed = 0
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
        await sleepAsync(100.millis)

      await subscribeNodes(nodes)
      await sleepAsync(1000.millis)

      for node in nodes:
        await node.publish("foobar", cast[seq[byte]]("Hello!"))
        await sleepAsync(100.millis)

      await sleepAsync(5000.millis)
      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)

      result = passed >= 10 # non deterministic, so at least 10 times

    check:
      waitFor(runTests()) == true

  test "FloodSub multiple peers, with self trigger":
    proc runTests(): Future[bool] {.async.} =
      var passed = 0
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
        await sleepAsync(100.millis)

      await subscribeNodes(nodes)
      await sleepAsync(1000.millis)

      for node in nodes:
        await node.publish("foobar", cast[seq[byte]]("Hello!"))
        await sleepAsync(100.millis)

      await sleepAsync(1.minutes)
      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)

      result = passed >= 20 # non deterministic, so at least 10 times

    check:
      waitFor(runTests()) == true
