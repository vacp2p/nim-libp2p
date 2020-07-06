import unittest

{.used.}

import ../../libp2p/[peerid, peerinfo,
                     crypto/crypto,
                     protocols/pubsub/rpc/message,
                     protocols/pubsub/rpc/messages]

let rng = initRng()

suite "Message":
  test "signature":
    let
      peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(peer, @[], "topic", sign = true)

    check verify(msg, peer)
