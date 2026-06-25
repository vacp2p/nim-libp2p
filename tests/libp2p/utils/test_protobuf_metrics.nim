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

  suite "protobuf_metrics":
    test "PeerRecord encode does not increment write counter (withMetrics = false)":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let peerId = PeerId.init(KeyPair.random(ECDSA, rng()).get().seckey).get()
      let record = PeerRecord.init(peerId, @[ma])
      let before = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      discard encode(record)
      let after = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      check after == before

    test "PeerRecord decode does not increment read counter (withMetrics = false)":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let peerId = PeerId.init(KeyPair.random(ECDSA, rng()).get().seckey).get()
      let record = PeerRecord.init(peerId, @[ma])
      let encoded = encode(record)
      let before = counterValue(libp2p_protobuf_bytes_read, "PeerRecord")
      discard PeerRecord.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_read, "PeerRecord")
      check after == before

    test "write counter incremented on encode":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      let encoded = encode(msg)
      let after = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      check after == before + float64(encoded.len)

    test "read counter incremented on decode":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      let decoded = MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      check decoded.isOk
      check after == before + float64(encoded.len)

    test "encode does not increment read counter":
      let msg = MetricsTestMsg(value: 42)
      let beforeRead = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      discard encode(msg)
      let afterRead = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      check afterRead == beforeRead

    test "decode does not increment write counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let beforeWrite = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      let afterWrite = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      check afterWrite == beforeWrite

    test "multiple encodes accumulate write counter":
      let msg = MetricsTestMsg(value: 42)
      let before = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      let enc1 = encode(msg)
      let enc2 = encode(msg)
      let after = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      check after == before + float64(enc1.len + enc2.len)

    test "multiple decodes accumulate read counter":
      let msg = MetricsTestMsg(value: 42)
      let encoded = encode(msg)
      let before = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      discard MetricsTestMsg.decode(encoded)
      discard MetricsTestMsg.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_read, "MetricsTestMsg")
      check after == before + float64(encoded.len * 2)

    test "counters track bytes per type label independently":
      let msg = MetricsTestMsg(value: 42)
      let beforeMsg = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      let beforeOther = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      discard encode(msg)
      let afterMsg = counterValue(libp2p_protobuf_bytes_write, "MetricsTestMsg")
      let afterOther = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      check afterMsg > beforeMsg
      check afterOther == beforeOther

    test "counter for unregistered label returns zero":
      check counterValue(libp2p_protobuf_bytes_read, "NonExistentType") == 0.0
      check counterValue(libp2p_protobuf_bytes_write, "NonExistentType") == 0.0
