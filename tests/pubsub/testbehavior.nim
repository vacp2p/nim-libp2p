{.used.}

import std/[sequtils]
import stew/byteutils
import utils
import chronicles
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message]
import ../helpers

const MsgIdSuccess = "msg id gen success"

suite "GossipSub Behavior":
  teardown:
    checkTrackers()

  asyncTest "handleIHave - peers with no budget should not request messages":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.subscribe(topic, voidTopicHandler)

    let peerId = randomPeerId()
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
      gossipSub.mcache.msgs.len == 1

  asyncTest "handleIHave - peers with budget should request messages":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.subscribe(topic, voidTopicHandler)

    let peerId = randomPeerId()
    let peer = gossipSub.getPubSubPeer(peerId)

    # Add message to `gossipSub`'s message cache
    let id = @[0'u8, 1, 2, 3]
    gossipSub.mcache.put(id, Message())
    peer.sentIHaves[^1].incl(id)

    # Build an IHAVE message that contains the same message ID three times
    # If ids are repeated, only one request should be generated
    let msg = ControlIHave(topicID: topic, messageIDs: @[id, id, id])

    # Given the budget is not 0 (because it's not been overridden)
    check:
      peer.iHaveBudget > 0

    # When a peer makes an IHAVE request for the a message that `gossipSub` does not have
    let iwants = gossipSub.handleIHave(peer, @[msg])

    # Then `gossipSub` should generate an IWant message for the message
    check:
      iwants.messageIDs.len == 1
      gossipSub.mcache.msgs.len == 1

  asyncTest "handleIWant - peers with budget should request messages":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.subscribe(topic, voidTopicHandler)

    let peerId = randomPeerId()
    let peer = gossipSub.getPubSubPeer(peerId)

    # Add message to `gossipSub`'s message cache
    let id = @[0'u8, 1, 2, 3]
    gossipSub.mcache.put(id, Message())
    peer.sentIHaves[^1].incl(id)

    # Build an IWANT message that contains the same message ID three times
    # If ids are repeated, only one request should be generated
    let msg = ControlIWant(messageIDs: @[id, id, id])

    # When a peer makes an IWANT request for the a message that `gossipSub` has
    let messages = gossipSub.handleIWant(peer, @[msg])

    # Then `gossipSub` should return the message
    check:
      messages.len == 1
      gossipSub.mcache.msgs.len == 1

  asyncTest "Max IDONTWANT messages per heartbeat per peer":
    # Given GossipSub node with 1 peer
    let
      topic = "foobar"
      totalPeers = 1

    let (gossipSub, conns, peers) = setupGossipSubWithPeers(totalPeers, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    let peer = peers[0]

    # And sequence of iDontWants with more messages than max number (1200)
    proc generateMessageIds(count: int): seq[MessageId] =
      return (0 ..< count).mapIt(("msg_id_" & $it & $Moment.now()).toBytes())

    let iDontWants =
      @[
        ControlIWant(messageIDs: generateMessageIds(600)),
        ControlIWant(messageIDs: generateMessageIds(600)),
      ]

    # When node handles iDontWants
    gossipSub.handleIDontWant(peer, iDontWants)

    # Then it saves max IDontWantMaxCount messages in the history and the rest is dropped
    check:
      peer.iDontWants[0].len == IDontWantMaxCount

  asyncTest "`replenishFanout` Degree Lo":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    check gossipSub.gossipsub[topic].len == 15
    gossipSub.replenishFanout(topic)
    check gossipSub.fanout[topic].len == gossipSub.parameters.d

  asyncTest "`dropFanoutPeers` drop expired fanout topics":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(6, topic, populateGossipsub = true, populateFanout = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.lastFanoutPubSub[topic] = Moment.fromNow(1.millis)
    await sleepAsync(5.millis) # allow the topic to expire 

    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic notin gossipSub.fanout

  asyncTest "`dropFanoutPeers` leave unexpired fanout topics":
    let
      topic1 = "foobar1"
      topic2 = "foobar2"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(
      6, @[topic1, topic2], populateGossipsub = true, populateFanout = true
    )
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.lastFanoutPubSub[topic1] = Moment.fromNow(1.millis)
    gossipSub.lastFanoutPubSub[topic2] = Moment.fromNow(1.minutes)
    await sleepAsync(5.millis) # allow first topic to expire 

    check gossipSub.fanout[topic1].len == gossipSub.parameters.d
    check gossipSub.fanout[topic2].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic1 notin gossipSub.fanout
    check topic2 in gossipSub.fanout

  asyncTest "`getGossipPeers` - should gather up to degree D non intersecting peers":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(45, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i in 0 ..< 30:
      let peer = peers[i]
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.grafted(peer, topic)
        gossipSub.mesh[topic].incl(peer)

    # generate gossipsub (free standing) peers
    for i in 30 ..< 45:
      let peer = peers[i]
      gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    check gossipSub.fanout[topic].len == 15
    check gossipSub.mesh[topic].len == 15
    check gossipSub.gossipsub[topic].len == 15

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d
    for p in gossipPeers.keys:
      check not gossipSub.fanout.hasPeerId(topic, p.peerId)
      check not gossipSub.mesh.hasPeerId(topic, p.peerId)

  asyncTest "`getGossipPeers` - should not crash on missing topics in mesh":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.fanout[topic].incl(peer)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d

  asyncTest "`getGossipPeers` - should not crash on missing topics in fanout":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.gossipsub[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == gossipSub.parameters.d

  asyncTest "`getGossipPeers` - should not crash on missing topics in gossip":
    let topic = "foobar"
    let (gossipSub, conns, peers) = setupGossipSubWithPeers(30, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # generate mesh and fanout peers 
    for i, peer in peers:
      if i mod 2 == 0:
        gossipSub.mesh[topic].incl(peer)
        gossipSub.grafted(peer, topic)
      else:
        gossipSub.fanout[topic].incl(peer)

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = conns[i]
      inc seqno
      let msg = Message.init(conn.peerId, ("HELLO" & $i).toBytes(), topic, some(seqno))
      gossipSub.mcache.put(gossipSub.msgIdProvider(msg).expect(MsgIdSuccess), msg)

    let gossipPeers = gossipSub.getGossipPeers()
    check gossipPeers.len == 0
