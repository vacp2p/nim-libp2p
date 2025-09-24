{.used.}

import results, unittest
import ../../libp2p/protocols/mix/mix_message
import stew/byteutils

# Define test cases
suite "mix_message_tests":
  test "serialize_and_deserialize_mix_message":
    let
      message = "Hello World!"
      codec = "/test/codec/1.0.0"
      mixMsg = MixMessage.init(message.toBytes(), codec)

    let serialized = mixMsg.serialize()
    let deserializedMsg =
      MixMessage.deserialize(serialized).expect("deserialization failed")

    check:
      message == string.fromBytes(deserializedMsg.message)
      codec == deserializedMsg.codec

  test "serialize_empty_mix_message":
    let
      emptyMessage = ""
      codec = "/test/codec/1.0.0"
      mixMsg = MixMessage.init(emptyMessage.toBytes(), codec)

    let serialized = mixMsg.serialize()
    let dMixMsg = MixMessage.deserialize(serialized).expect("deserialization failed")

    check:
      emptyMessage == string.fromBytes(dMixMsg.message)
      codec == dMixMsg.codec
