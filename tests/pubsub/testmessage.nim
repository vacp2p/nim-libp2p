import unittest

import ../../libp2p/[peer, peerinfo,
                     crypto/crypto,
                     protocols/pubsub/rpc/message,
                     protocols/pubsub/rpc/messages]

suite "Message":
  test "signature":
    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA).get()).get()
      msg = Message.init(peer, @[], "topic", sign = true)

    check verify(msg, peer)
