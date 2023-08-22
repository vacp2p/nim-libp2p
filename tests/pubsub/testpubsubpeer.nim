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
      topic = "test_topic"
      peer = gossipSub.getPubSubPeer(randomPeerId())
      largeMessageSize = peer.maxMessageSize div 2 + 100  # Just over half the max size

    # Create a dummy ControlMessage
    let
      graft = @[ControlGraft(topicID: "topic1")]
      prune = @[ControlPrune(topicID: "topic2")]
      ihave = @[ControlIHave(topicID: "topic3", messageIDs: @[@[1'u8, 2, 3], @[4'u8, 5, 6]])]
      iwant = @[ControlIWant(messageIDs: @[@[7'u8, 8, 9]])]

    let control = some(ControlMessage(
      graft: graft,
      prune: prune,
      ihave: ihave,
      iwant: iwant
    ))

    # Create a message that's just over half the max size
    let largeMessage = Message(data: newSeq[byte](largeMessageSize))

    # Create an RPCMsg with two such messages, making it oversized
    var oversizedMsg = RPCMsg(messages: @[largeMessage, largeMessage], control: control)

    # Mock the sendEncoded function to capture the messages being sent
    var sentMessages = peer.send(oversizedMsg, false)

    # The first split message should have the control data, others shouldn't
    check: sentMessages[0].control == control
    for i in 1..<sentMessages.len:
      check: sentMessages[i].control.isNone

    # Check if the send function correctly split and sent the RPCMsg
    check:
      sentMessages.len == 2
      sentMessages[0].messages[0].data.len == largeMessageSize
      sentMessages[1].messages[0].data.len == largeMessageSize

    # If the original message is below maxMessageSize, it's sent as-is
    var smallMsg = RPCMsg(messages: @[Message(data: newSeqOfCap[byte](peer.maxMessageSize div 2))], control: control)

    let sentSmallMessages = peer.send(smallMsg, false)
    check: sentSmallMessages.len == 1
    check: sentSmallMessages[0] == smallMsg
