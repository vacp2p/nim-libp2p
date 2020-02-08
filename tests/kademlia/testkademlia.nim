import unittest, sequtils, options
import chronos
import utils,
       ../../libp2p/[switch,
                     crypto/crypto,
                     protocols/kademlia/kademlia]

suite "Kademlia":
  test "Kademlia basic ping":
    proc runTests(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      proc handler(data: string) {.async, gcsafe.} =
        echo("Hit handler in kademlia ping ", data)
        completionFut.complete(true)

      # TODO: Ensure these nodes have right characteristics
      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start())) # Alice
      awaiters.add((await nodes[1].start())) # Bob

      await listenAllNodes(nodes)
      # XXX: Unclear if this is right abstraction, ping/find_node
      # Equivalent 1-1 messages, vs pub/sub which are 1:N/N:1
      await nodes[1].listenForPing(handler)
      await sleepAsync(1000.millis)

      # This can probably be peer ID only, then look up table etc
      await nodes[0].ping(nodes[1].peerInfo)

      result = await completionFut
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)

    check:
      waitFor(runTests()) == true

#  test "Kademlia add contact (XXX)":
#    proc runTests(): Future[bool] {.async.} =
#      var completionFut = newFuture[bool]()
#      proc handler(data: string) {.async, gcsafe.} =
#        echo("Hit handler in kademlia ping ", data)
#        completionFut.complete(true)
#
#      # TODO: Ensure these nodes have right characteristics
#      var nodes = generateNodes(2)
#      var awaiters: seq[Future[void]]
#      awaiters.add((await nodes[0].start())) # Alice
#      awaiters.add((await nodes[1].start())) # Bob
#
#      # XXX: Strictly speaking only A listens to B here
#      await listenAllNodes(nodes)
#
#      # XXX: Only adding contact and printing, no actual assertion
#      discard nodes[0].addContact(nodes[1].peerInfo)
#      completionFut.complete(true)
#
#      result = await completionFut
#      await allFutures(nodes[0].stop(), nodes[1].stop())
#      await allFutures(awaiters)
#
#    check:
#      waitFor(runTests()) == true
#
  test "Kademlia find node (WIP)":
    proc runTests(): Future[bool] {.async.} =
      var completionFut = newFuture[bool]()
      # XXX: handler signature
      proc handler(data: string) {.async, gcsafe.} =
        echo("Hit handler in find node lol ", data)
        completionFut.complete(true)

      # TODO: Ensure these nodes have right characteristics
      var nodes = generateNodes(2)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start())) # Alice
      awaiters.add((await nodes[1].start())) # Bob

      # XXX: Strictly speaking only A listens to B here
      # We need peer info from connection via switch here
      # XXX: Figure out how this works with addPeer, etc
      await listenAllNodes(nodes)

      # TODO: Replace with better here
      # XXX: Only adding contact and printing, no actual assertion
      discard nodes[0].addContact(nodes[1].peerInfo)

      await nodes[1].listenForFindNode(handler)

      #await nodes[1].listenForFindNode()
      #completionFut.complete(true)

      echo("Finding node (self): ", nodes[0].peerInfo.peerId)
      discard nodes[0].iterativeFindNode(nodes[0].peerInfo.peerId)
      # XXX

      # XXX: Unclear if this is right abstraction, ping/find_node
      # Equivalent 1-1 messages, vs pub/sub which are 1:N/N:1
      #await nodes[1].listenForPing(handler)
      #
      await sleepAsync(3000.millis)

      #completionFut.complete(true)

      # This can probably be peer ID only, then look up table etc
      #await nodes[0].ping(nodes[1].peerInfo)

      result = await completionFut
      await allFutures(nodes[0].stop(), nodes[1].stop())
      await allFutures(awaiters)

    check:
      waitFor(runTests()) == true



# TODO: test "Kademlia basic find node":
# HERE ATM. Basic add contact, then find node. Finally.
