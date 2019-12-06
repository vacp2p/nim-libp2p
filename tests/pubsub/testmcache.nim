import options, sets, sequtils
import unittest
import ../../libp2p/[peer,
                     crypto/crypto,
                     protocols/pubsub/mcache,
                     protocols/pubsub/rpc/message,
                     protocols/pubsub/rpc/messages]

suite "MCache":
  test "put/get":
    var mCache = newMCache(3, 5)
    var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                       seqno: cast[seq[byte]]("12345"))
    mCache.put(msg)
    check mCache.get(msg.msgId).isSome and mCache.get(msg.msgId).get() == msg

  test "window":
    var mCache = newMCache(3, 5)

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["foo"])
      mCache.put(msg)

    for i in 0..<5:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["bar"])
      mCache.put(msg)

    var mids = mCache.window("foo")
    check mids.len == 3

    var id = toSeq(mids)[0]
    check mCache.get(id).get().topicIDs[0] == "foo"

  test "shift - shift 1 window at a time":
    var mCache = newMCache(1, 5)

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["foo"])
      mCache.put(msg)

    mCache.shift()
    check mCache.window("foo").len == 0

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["bar"])
      mCache.put(msg)

    mCache.shift()
    check mCache.window("bar").len == 0

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["baz"])
      mCache.put(msg)

    mCache.shift()
    check mCache.window("baz").len == 0

  test "shift - 2 windows at a time":
    var mCache = newMCache(1, 5)

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["foo"])
      mCache.put(msg)

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["bar"])
      mCache.put(msg)

    for i in 0..<3:
      var msg = Message(fromPeer: PeerID.init(PrivateKey.random(RSA)).data,
                        seqno: cast[seq[byte]]("12345"),
                        topicIDs: @["baz"])
      mCache.put(msg)

    mCache.shift()
    check mCache.window("foo").len == 0

    mCache.shift()
    check mCache.window("bar").len == 0
