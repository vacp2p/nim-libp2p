# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import utils, ../../libp2p/[protocols/pubsub/pubsub,
                            protocols/pubsub/pubsubpeer,
                            protocols/pubsub/rpc/messages,
                            protocols/pubsub/rpc/protobuf]
import ../helpers

suite "GossipSub":
  teardown:
    checkTrackers()

  test "Test oversized RPCMsg splitting":
    let
      gossipSub = TestGossipSub.init(newStandardSwitch())
      maxMessageSize = 1048576  # 1MB for example, adjust as needed
      topic = "test_topic"
      largeMessageSize = maxMessageSize div 2 + 100  # Just over half the max size
      peer = gossipSub.getPubSubPeer(randomPeerId())

    # Create a message that's just over half the max size
    let largeMessage = Message(data: newSeq[byte](largeMessageSize))

    # Create an RPCMsg with two such messages, making it oversized
    var oversizedMsg = RPCMsg(messages: @[largeMessage, largeMessage])

    # Mock the sendEncoded function to capture the messages being sent
    var sentMessages = peer.send(oversizedMsg, false)

    # Check if the send function correctly split and sent the RPCMsg
    check:
      sentMessages.len == 2
      sentMessages[0].messages[0].data.len == largeMessageSize
      sentMessages[1].messages[0].data.len == largeMessageSize
