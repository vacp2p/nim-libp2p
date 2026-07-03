# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

when defined(libp2p_protobuf_metrics):
  import protobuf_serialization
  import
    ../../../libp2p/
      [routing_record, utils/protobuf, utils/protobuf_metrics, crypto/crypto]
  import ../../tools/[unittest, crypto]

  # A type that explicitly opts into metrics tracking.
  type MetricsTestMsg* {.proto2.} = object
    value* {.fieldNumber: 1, required, pint.}: uint64

  Protobuf.serializerFor([MetricsTestMsg], withMetrics = true, domain = "test")

  template counterValue(counter: untyped, label: string): float64 =
    try:
      counter.value(["test." & label])
    except exceptions.KeyError:
      0.0

  proc makePeerRecord(): PeerRecord =
    PeerRecord.init(
      PeerId.random(rng()).get(), @[MultiAddress.init("/ip4/127.0.0.1/tcp/1234").get()]
    )

  suite "protobuf_metrics":
    test "PeerRecord encode does not increment sent counter (withMetrics = false)":
      let record = makePeerRecord()
      let before = counterValue(libp2p_protobuf_bytes_sent, "PeerRecord")
      discard encode(record)
      let after = counterValue(libp2p_protobuf_bytes_sent, "PeerRecord")
      check after == before

    test "PeerRecord decode does not increment received counter (withMetrics = false)":
      let record = makePeerRecord()
      let encoded = encode(record)
      let before = counterValue(libp2p_protobuf_bytes_received, "PeerRecord")
      discard PeerRecord.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_received, "PeerRecord")
      check after == before

    test "sent counter incremented on encode":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      let encoded = encode(msg)
      let after = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      check after == before + float64(encoded.len)

    test "received counter incremented on decode":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      let decoded = MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      check decoded.isOk
      check after == before + float64(encoded.len)

    test "encode does not increment received counter":
      let msg = MetricsTestMsg(value: 42)
      let beforeRead = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      discard encode(msg)
      let afterRead = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      check afterRead == beforeRead

    test "decode does not increment sent counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let beforeWrite = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      let afterWrite = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      check afterWrite == beforeWrite

    test "multiple encodes accumulate sent counter":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      let enc1 = encode(msg)
      let enc2 = encode(msg)
      let after = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      check after == before + float64(enc1.len + enc2.len)

    test "multiple decodes accumulate received counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      discard MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_received, "MetricsTestMsg")
      check after == before + float64(encoded.len * 2)

    test "counters track bytes per type label independently":
      let msg = MetricsTestMsg(value: 42)
      let beforeMsg = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      let beforeOther = counterValue(libp2p_protobuf_bytes_sent, "PeerRecord")
      discard encode(msg)
      let afterMsg = counterValue(libp2p_protobuf_bytes_sent, "MetricsTestMsg")
      let afterOther = counterValue(libp2p_protobuf_bytes_sent, "PeerRecord")
      check afterMsg > beforeMsg
      check afterOther == beforeOther

    test "counter for unregistered label returns zero":
      check counterValue(libp2p_protobuf_bytes_received, "NonExistentType") == 0.0
      check counterValue(libp2p_protobuf_bytes_sent, "NonExistentType") == 0.0

    test "messages_sent counter incremented on encode":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      discard encode(msg)
      let after = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      check after == before + 1.0

    test "messages_received counter incremented on decode":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      check after == before + 1.0

    test "encode does not increment messages_received counter":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      discard encode(msg)
      let after = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      check after == before

    test "decode does not increment messages_sent counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      check after == before

    test "multiple encodes accumulate messages_sent counter":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      discard encode(msg)
      discard encode(msg)
      let after = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      check after == before + 2.0

    test "multiple decodes accumulate messages_received counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      discard MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_messages_received, "MetricsTestMsg")
      check after == before + 2.0

    test "messages counters track per type label independently":
      let msg = MetricsTestMsg(value: 42)
      let beforeMsg = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      let beforeOther = counterValue(libp2p_protobuf_messages_sent, "PeerRecord")
      discard encode(msg)
      let afterMsg = counterValue(libp2p_protobuf_messages_sent, "MetricsTestMsg")
      let afterOther = counterValue(libp2p_protobuf_messages_sent, "PeerRecord")
      check afterMsg > beforeMsg
      check afterOther == beforeOther

    test "messages_sent counter for unregistered label returns zero":
      check counterValue(libp2p_protobuf_messages_sent, "NonExistentType") == 0.0

    test "messages_received counter for unregistered label returns zero":
      check counterValue(libp2p_protobuf_messages_received, "NonExistentType") == 0.0
