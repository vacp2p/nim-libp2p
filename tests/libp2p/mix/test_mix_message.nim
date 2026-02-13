# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import results, stew/byteutils
import ../../../libp2p/protocols/mix/[mix_message, mix_protocol]
import ../../tools/[unittest]

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

  test "getMaxMessageSizeForCodec returns correct size":
    let codec = "/test/1.0.0"

    let size0 = getMaxMessageSizeForCodec(codec, 0)
    check:
      size0.isOk
      size0.get() > 0

    # Adding 1 SURB should reduce available size by a fixed amount (SurbSize)
    let size1 = getMaxMessageSizeForCodec(codec, 1)
    check:
      size1.isOk
      size1.get() < size0.get()
    let surbOverhead = size0.get() - size1.get()

    # Adding 2 SURBs should reduce by exactly double the per-SURB overhead
    let size2 = getMaxMessageSizeForCodec(codec, 2)
    check:
      size2.isOk
      size2.get() == size0.get() - 2 * surbOverhead

    # A longer codec should return a smaller max message size
    let longCodec = "/test/with/a/much/longer/codec/name/1.0.0"
    let sizeLong = getMaxMessageSizeForCodec(longCodec, 0)
    check:
      sizeLong.isOk
      sizeLong.get() < size0.get()

  test "getMaxMessageSizeForCodec errors when overhead exceeds capacity":
    let codec = "/test/1.0.0"

    check:
      getMaxMessageSizeForCodec(codec, 5).isOk # 5 SURB is max
      getMaxMessageSizeForCodec(codec, 6).isErr
