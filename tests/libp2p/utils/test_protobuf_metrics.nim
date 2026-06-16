# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

when defined(libp2p_protobuf_metrics):
  import ../../../libp2p/[routing_record, utils/protobuf_metrics]
  import ../../tools/[unittest]

  template counterValue(counter: untyped, label: string): float64 =
    try:
      counter.value([label])
    except exceptions.KeyError:
      0.0

  suite "protobuf_metrics":
    test "write counter incremented on encode":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let before = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      let encoded = encode(record)
      let after = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      check after == before + float64(encoded.len)

    test "read counter incremented on decode":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let encoded = encode(record)
      let before = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      let decoded = AddressInfo.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      check decoded.isOk
      check after == before + float64(encoded.len)

    test "encode does not increment read counter":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let beforeRead = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      discard encode(record)
      let afterRead = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      check afterRead == beforeRead

    test "decode does not increment write counter":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let encoded = encode(record)
      let beforeWrite = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      discard AddressInfo.decode(encoded)
      let afterWrite = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      check afterWrite == beforeWrite

    test "multiple encodes accumulate write counter":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let before = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      let enc1 = encode(record)
      let enc2 = encode(record)
      let after = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      check after == before + float64(enc1.len + enc2.len)

    test "multiple decodes accumulate read counter":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let record = AddressInfo(address: ma)
      let encoded = encode(record)
      let before = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      discard AddressInfo.decode(encoded)
      discard AddressInfo.decode(encoded)
      let after = counterValue(libp2p_protobuf_bytes_read, "AddressInfo")
      check after == before + float64(encoded.len * 2)

    test "counters track bytes per type label independently":
      let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").tryGet()
      let addrInfo = AddressInfo(address: ma)
      let beforeAddr = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      let beforePeer = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      discard encode(addrInfo)
      let afterAddr = counterValue(libp2p_protobuf_bytes_write, "AddressInfo")
      let afterPeer = counterValue(libp2p_protobuf_bytes_write, "PeerRecord")
      check afterAddr > beforeAddr
      check afterPeer == beforePeer

    test "counter for unregistered label returns zero":
      check counterValue(libp2p_protobuf_bytes_read, "NonExistentType") == 0.0
      check counterValue(libp2p_protobuf_bytes_write, "NonExistentType") == 0.0
