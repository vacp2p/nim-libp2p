# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils]
import stew/byteutils
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message]
import ../helpers

const MsgIdSuccess = "msg id gen success"

suite "GossipSub Gossip Protocol":
  teardown:
    checkTrackers()

  asyncTest "`getGossipPeers` - should gather up to degree D non intersecting peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()

    # generate mesh and fanout peers
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d
    for p in peers.keys:
      check not gossipSub.fanout.hasPeerId(topic, p.peerId)
      check not gossipSub.mesh.hasPeerId(topic, p.peerId)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      inc seqno
      let msg = Message.init(peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let peers = gossipSub.getGossipPeers()
    check peers.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "handleIHave/Iwant tests":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      check false

    proc handler2(topic: string, data: seq[byte]) {.async.} =
      discard

    let topic = "foobar"
    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.subscribe(topic, handler2)

    # Instantiates 30 peers and connects all of them to the previously defined `gossipSub`
    for i in 0 ..< 30:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      # Add the connection to `gossipSub`, to their `gossipSub.gossipsub` and `gossipSub.mesh` tables
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    # Peers with no budget should not request messages
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      # Add message to `gossipSub`'s message cache
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      # Build an IHAVE message that contains the same message ID three times
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      # Given the peer has no budget to request messages
      peer.iHaveBudget = 0
      # When a peer makes an IHAVE request for the a message that `gossipSub` has
      let iwants = gossipSub.handleIHave(peer, @[msg])
      # Then `gossipSub` should not generate an IWant message for the message, 
      check:
        iwants.messageIDs.len == 0

    # Peers with budget should request messages. If ids are repeated, only one request should be generated
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      let id = @[0'u8, 1, 2, 3]
      # Build an IHAVE message that contains the same message ID three times
      let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])
      # Given the budget is not 0 (because it's not been overridden)
      # When a peer makes an IHAVE request for the a message that `gossipSub` does not have
      let iwants = gossipSub.handleIHave(peer, @[msg])
      # Then `gossipSub` should generate an IWant message for the message
      check:
        iwants.messageIDs.len == 1

    # Peers with budget should request messages. If ids are repeated, only one request should be generated
    block:
      # Define a new connection
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      # Add message to `gossipSub`'s message cache
      let id = @[0'u8, 1, 2, 3]
      gossipSub.mcache.put(id, Message())
      peer.sentIHaves[^1].incl(id)
      # Build an IWANT message that contains the same message ID three times
      let msg = ControlIWant(messageIDs: @[id, id, id])
      # When a peer makes an IWANT request for the a message that `gossipSub` has
      let genmsg = gossipSub.handleIWant(peer, @[msg])
      # Then `gossipSub` should return the message
      check:
        genmsg.len == 1

    check gossipSub.mcache.msgs.len == 1

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()
