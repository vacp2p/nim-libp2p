import unittest, sequtils, options
import chronos
import utils,
       ../../libp2p/[switch,
                     crypto/crypto,
                     protocols/kademlia/kademlia]

suite "Kademlia":
  test "Kademlia 1+1":
    check:
      1+1 == 2

  test "Kademlia basic ping find node (XXX: bad test)":
    proc runTests(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      proc handler(data: seq[byte]) {.async, gcsafe.} =
        # TODO: Return something, anything, here, like a pong
        # TODO: Then return closest known node here
        echo("***handler")
        completionFut.complete(true)

      # TODO: Ensure these nodes have right characteristics
      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))
      echo("***4")

      # We aren't subscribing to anything here, it is an RPC
      # What does subscribeNodes(nodes) do?
      # Where does handler come in?
      # await nodes[1].subscribe("foobar", handler)

      await nodes[0].ping(nodes[1].peerInfo, handler)

      # TODO: Use start handler here
      await sleepAsync(1000.millis)

      # Not publishing either, but sending to nodes[1]
      # TODO: Look at publish interface and make (direct) send one
      # TODO: This should be protobuf message
      #await nodes[0].send("find_node(1)")

      # XXX: should be in handler above
      completionFut.complete(true)

      result = await completionFut
      echo("***5")
      # TODO: Ensure stop methods
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)
      echo("***6")

    check:
      waitFor(runTests()) == true
