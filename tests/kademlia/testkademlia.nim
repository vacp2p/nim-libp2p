import unittest, sequtils, options
import chronos, chronicles
import utils,
       ../../libp2p/[switch,
                     crypto/crypto,
                     protocols/kademlia/kademlia,
                     protocols/kademlia/kadpeer,
                     protocols/kademlia/rpc/messages,
                     protocols/kademlia/rpc/protobuf]

logScope:
  topic = "testKademlia"

suite "Kademlia":
#  test "Kademlia encode and decode ping":
#
#    # Testing encoding and decoding ping
#    var pingMessage = RPCMsg(strtype: "PING")
#    debug "pingMessage", msg = pingMessage
#
#    var encodedPing = encodeRpcMsg(pingMessage)
#    debug "pingMessage encoded", encoded = encodedPing
#
#    var decodedPing = decodeRpcMsg(encodedPing.buffer)
#    debug "pingMessage decoded", decoded = decodedPing
#
#    check:
#      decodedPing.strtype == "PING"
#
#  test "Kademlia encode and decode find node":
#
#    # Example peer
#    var pstr = "Qmdxy8GAu1pvi35xBAie9sMpMN4G9p6GK6WCNbSCDCDgyp"
#    var pid = PeerID.init(pstr)
#    debug "peer id", id = pid.pretty
#
#    # Testing encoding and decoding find node
#    var findNodeMessage = RPCMsg(strtype: "FIND_NODE", key: pid.getBytes())
#    debug "findNode", msg = findNodeMessage
#
#    var encodedFindNode = encodeRpcMsg(findNodeMessage)
#    debug "findNode encoded", encoded = encodedFindNode
#
#    var decodedFindNode = decodeRpcMsg(encodedFindNode.buffer)
#    debug "findNode decoded", decoded = decodedFindNode
#
#    var decodedId =  PeerID.init(decodedFindNode.key)
#    debug "findNode decoded id", id = decodedId.pretty
#
#    check:
#      pstr == decodedId.pretty
#
#  test "Kademlia basic ping":
#    proc runTests(): Future[bool] {.async.} =
#      var completionFut = newFuture[bool]()
#      proc handler(data: RPCMsg) {.async, gcsafe.} =
#        debug "Basic ping handler", data=data
#        completionFut.complete(true)
#
#      # TODO: Ensure these nodes have right characteristics
#      var nodes = generateNodes(2)
#      var awaiters: seq[Future[void]]
#      awaiters.add((await nodes[0].start())) # Alice
#      awaiters.add((await nodes[1].start())) # Bob
#
#      await listenAllNodes(nodes)
#      # XXX: Unclear if this is right abstraction, ping/find_node
#      # Equivalent 1-1 messages, vs pub/sub which are 1:N/N:1
#      await nodes[1].listenForPing(handler)
#      await sleepAsync(1000.millis)
#
#      # This can probably be peer ID only, then look up table etc
#      await nodes[0].ping(nodes[1].peerInfo)
#
#      result = await completionFut
#      await allFutures(nodes[0].stop(), nodes[1].stop())
#      await allFutures(awaiters)
#
#    check:
#      waitFor(runTests()) == true
#
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
      proc handler(data: seq[KadPeer]) {.async, gcsafe.} =
        debug "Find node RPC hit", data=data
        completionFut.complete(true)

      # TODO: Ensure these nodes have right characteristics
      var nodes = generateNodes(6)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start())) # Alice
      awaiters.add((await nodes[1].start())) # Bob
      awaiters.add((await nodes[2].start())) # Charlie

      awaiters.add((await nodes[3].start())) # D
      awaiters.add((await nodes[4].start())) # E
      awaiters.add((await nodes[5].start())) # F

      # XXX: Strictly speaking only A listens to B here
      # We need peer info from connection via switch here
      # XXX: Figure out how this works with addPeer, etc
      await listenAllNodes(nodes)

      # TODO: Replace with better here
      # XXX: Only adding contact and printing, no actual assertion
      discard nodes[0].addContact(nodes[1].peerInfo)

      # More add contacts
      # Assume Bob is already connected to Charlie, and D..F
      discard nodes[1].addContact(nodes[2].peerInfo)
      discard nodes[1].addContact(nodes[3].peerInfo)
      discard nodes[1].addContact(nodes[4].peerInfo)
      discard nodes[1].addContact(nodes[5].peerInfo)

      await nodes[1].listenForFindNode(handler)
      # TODO: Not what we want, we want to wait for response

      #await nodes[1].listenForFindNode()
      #completionFut.complete(true)

      debug "finding node (self)", self = nodes[0].peerInfo.peerId
      discard nodes[0].iterativeFindNode(nodes[0].peerInfo.peerId)
      # XXX

      # XXX: Unclear if this is right abstraction, ping/find_node
      # Equivalent 1-1 messages, vs pub/sub which are 1:N/N:1
      #await nodes[1].listenForPing(handler)
      #

      await sleepAsync(1000.millis)
      debug "Awaiting response from find node request"
      await sleepAsync(3000.millis)

      #completionFut.complete(true)

      # This can probably be peer ID only, then look up table etc
      #await nodes[0].ping(nodes[1].peerInfo)

      result = await completionFut
      await allFutures(nodes[0].stop(),
                       nodes[1].stop(),
                       nodes[2].stop(),
                       nodes[3].stop(),
                       nodes[4].stop(),
                       nodes[5].stop())
      await allFutures(awaiters)

    check:
      waitFor(runTests()) == true



# TODO: test "Kademlia basic find node":
# HERE ATM. Basic add contact, then find node. Finally.
