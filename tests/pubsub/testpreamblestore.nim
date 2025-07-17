import unittest2

{.used.}

import chronos
import
  ../../libp2p/[
    peerid,
    protocols/pubsub/gossipsub/preamblestore,
    protocols/pubsub/gossipsub/types,
    protocols/pubsub/rpc/message,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/rpc/messages,
  ]
import ../utils/async_tests
import ./utils
import ../helpers

proc mockPreamble(
    id: MessageId,
    sender: PubSubPeer,
    startOffset: Duration = 0.seconds,
    expireOffset: Duration = 10.seconds,
): PreambleInfo =
  let now = Moment.now()
  PreambleInfo.init(
    ControlPreamble(messageID: id, messageLength: 123, topicID: "test"),
    sender = sender,
    startsAt = now + startOffset,
    expiresAt = now + expireOffset,
  )

suite "preamble store":
  teardown:
    checkTrackers()

  var store {.threadvar.}: PreambleStore

  asyncSetup:
    store = PreambleStore.init()

  asyncTest "insert and retrieve":
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let info = mockPreamble(m1, peer, 0.seconds, 5.seconds)

    store.insert(m1, info)
    check:
      store.hasKey(m1)
      store[m1] == info

  asyncTest "heap order is preserved on inserts":
    for i in 0 .. 9:
      let id = MessageId(@[i.byte])
      let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
      let p = mockPreamble(id, peer, 0.seconds, i.seconds)
      store.insert(id, p)

    var last = Moment.low()
    while true:
      let popped = store.popExpired(Moment.now() + 20.seconds)
      if popped.isNone:
        break
      check popped.get().expiresAt >= last
      last = popped.get().expiresAt

  asyncTest "deletion marks AND heap pop discards deleted":
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let m2 = MessageId(@[2.byte, 2.byte, 2.byte])

    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    let p1 = mockPreamble(m1, peer, 0.seconds, 1.seconds)
    let p2 = mockPreamble(m2, peer, 0.seconds, 2.seconds)
    store.insert(m1, p1)
    store.insert(m2, p2)
    store.del(m1)
    # p1 is now deleted in heap, but still there
    let res = store.popExpired(Moment.now() + 5.seconds)
    check:
      res.isSome()
      res.get().messageId == m2 # p1 was skipped

  asyncTest "overwrite twice keeps latest, heap has garbage record":
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    let a1 = mockPreamble(m1, peer, 0.seconds, 1.seconds)
    let a2 = mockPreamble(m1, peer, 0.seconds, 5.seconds)
    store.insert(m1, a1)
    store.insert(m1, a2) # a1 is marked deleted but still in heap

    let res = store.popExpired(Moment.now() + 2.seconds)
    check res.isNone() # a1 is expired but ignored

    let res2 = store.popExpired(Moment.now() + 10.seconds)
    check:
      res2.isSome()
      res2.get().messageId == m1

  asyncTest "possiblePeersToQuery is affected by eviction and caps at 6":
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])

    var store = PreambleStore.init()
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    store.insert(m1, mockPreamble(m1, peer))

    # add 10 peers — only last 6 should survive
    var peersInserted: seq[PeerId] = @[]
    for i in 0 ..< 10:
      let peerId = randomPeerId()
      peersInserted.add(peerId)
      let peer = PubSubPeer.new(peerId, nil, nil, GossipSubCodec_12, 0)
      store.addPossiblePeerToQuery(m1, peer)

    let peersToQuery = store[m1].possiblePeersToQuery()
    check:
      peersToQuery.len == 6
      peersToQuery == peersInserted[4 ..< 10]

  asyncTest "re-adding same peer doesn't evict or reorder":
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)

    store.insert(m1, mockPreamble(m1, peer))

    for _ in 0 .. 10:
      store.addPossiblePeerToQuery(m1, peer)

    let peersToQuery = store[m1].possiblePeersToQuery()
    check:
      peersToQuery.len == 1
      peersToQuery[0] == peer.peerId

  asyncTest "withValue macro works sanely":
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    store.insert(m1, mockPreamble(m1, peer))

    var inside = false
    store.withValue(m1, val):
      check val.messageId == m1
      inside = true
    check inside

  asyncTest "len matches insert/delete":
    check store.len == 0
    let m1 = MessageId(@[1.byte, 1.byte, 1.byte])
    let peer = PubSubPeer.new(randomPeerId(), nil, nil, GossipSubCodec_12, 0)
    store.insert(m1, mockPreamble(m1, peer))
    check store.len == 1
    store.del(m1)
    check store.len == 0
